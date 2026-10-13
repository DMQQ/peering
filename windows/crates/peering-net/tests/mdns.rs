use std::cell::RefCell;
use std::rc::Rc;

use peering_net::mdns::{
    service_instance_name, txt_records, Advertiser, MdnsError, ServiceAdvert, ServiceRegistry, SERVICE_TYPE,
};

#[derive(Default, Clone)]
struct FakeRegistry {
    calls: Rc<RefCell<Vec<String>>>,
}

impl FakeRegistry {
    fn calls(&self) -> Vec<String> {
        self.calls.borrow().clone()
    }
}

impl ServiceRegistry for FakeRegistry {
    fn register(&mut self, advert: &ServiceAdvert) -> Result<String, MdnsError> {
        self.calls.borrow_mut().push(format!("register {}", advert.instance_name));
        Ok(format!("{}.{SERVICE_TYPE}", advert.instance_name))
    }

    fn unregister(&mut self, fullname: &str) -> Result<(), MdnsError> {
        self.calls.borrow_mut().push(format!("unregister {fullname}"));
        Ok(())
    }
}

fn advert() -> ServiceAdvert {
    ServiceAdvert::new("0F6B2C1E-8D4A-4B7E-9C3D-1A2B3C4D5E6F", "Studio Mac", 51515)
}

#[test]
fn txt_records_carry_id_name_and_version() {
    let records = txt_records("ABC", "Studio Mac", "20");
    assert_eq!(
        records,
        vec![
            ("id".to_owned(), "ABC".to_owned()),
            ("name".to_owned(), "Studio Mac".to_owned()),
            ("v".to_owned(), "20".to_owned()),
        ]
    );
}

#[test]
fn an_ordinary_name_is_its_own_instance_name() {
    assert_eq!(service_instance_name("Studio Mac"), "Studio Mac");
}

#[test]
fn dots_backslashes_and_control_characters_are_replaced() {
    assert_eq!(service_instance_name("Mac.mini\\two\tthree"), "Mac mini two three");
}

#[test]
fn a_long_name_is_cut_to_63_bytes_on_a_character_boundary() {
    let name = "é".repeat(40);
    let instance = service_instance_name(&name);
    assert!(instance.len() <= 63);
    assert_eq!(instance.len(), 62);
    assert!(instance.chars().all(|character| character == 'é'));
}

#[test]
fn a_blank_name_falls_back_to_a_fixed_instance_name() {
    assert_eq!(service_instance_name("   "), "Peering");
    assert_eq!(service_instance_name(".."), "Peering");
}

#[test]
fn the_advert_uses_the_device_id_as_host_name_and_the_host_port() {
    let advert = advert();
    assert_eq!(advert.host_name, "0f6b2c1e-8d4a-4b7e-9c3d-1a2b3c4d5e6f.local.");
    assert_eq!(advert.port, 51515);
    assert_eq!(advert.txt.last().map(|(key, value)| (key.as_str(), value.as_str())), Some(("v", "20")));
}

#[test]
fn starting_registers_once_and_reports_advertising() {
    let registry = FakeRegistry::default();
    let advertiser = Advertiser::start(registry.clone(), advert()).expect("starts");
    assert!(advertiser.is_advertising());
    assert_eq!(registry.calls(), vec!["register Studio Mac".to_owned()]);
}

#[test]
fn a_connected_client_withdraws_and_the_last_disconnect_re_advertises() {
    let registry = FakeRegistry::default();
    let mut advertiser = Advertiser::start(registry.clone(), advert()).expect("starts");

    advertiser.set_connected_clients(1).expect("withdraws");
    assert!(!advertiser.is_advertising());

    advertiser.set_connected_clients(0).expect("re-advertises");
    assert!(advertiser.is_advertising());

    assert_eq!(
        registry.calls(),
        vec![
            "register Studio Mac".to_owned(),
            "unregister Studio Mac._remotedesktop._tcp.local.".to_owned(),
            "register Studio Mac".to_owned(),
        ]
    );
}

#[test]
fn further_client_counts_do_not_repeat_the_registry_calls() {
    let registry = FakeRegistry::default();
    let mut advertiser = Advertiser::start(registry.clone(), advert()).expect("starts");

    advertiser.set_connected_clients(1).expect("withdraws");
    advertiser.set_connected_clients(2).expect("stays withdrawn");
    advertiser.set_connected_clients(0).expect("re-advertises");
    advertiser.set_connected_clients(0).expect("stays advertised");

    assert_eq!(registry.calls().len(), 3);
}
