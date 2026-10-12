//! Tests for the menu and pairing models.

mod menu {
    use super::super::*;

    fn snapshot(hosting: bool, relay: RelayStatus, clients: usize) -> HostSnapshot {
        HostSnapshot { hosting, relay, connected_clients: clients, ..HostSnapshot::default() }
    }

    fn label_of(model: &MenuModel, action: MenuAction) -> &'static str {
        model.entries().into_iter().find(|entry| entry.action == action).expect("the entry exists").label
    }

    #[test]
    fn the_first_entry_offers_to_stop_while_hosting_and_to_start_otherwise() {
        assert_eq!(label_of(&MenuModel::new(snapshot(true, RelayStatus::Off, 0)), MenuAction::ToggleHosting), strings::STOP_HOSTING);
        assert_eq!(label_of(&MenuModel::new(snapshot(false, RelayStatus::Off, 0)), MenuAction::ToggleHosting), strings::START_HOSTING);
    }

    #[test]
    fn the_pairing_code_is_offered_only_while_hosting() {
        let hosting = MenuModel::new(snapshot(true, RelayStatus::Off, 0));
        let stopped = MenuModel::new(snapshot(false, RelayStatus::Off, 0));
        let enabled = |model: &MenuModel| {
            model.entries().into_iter().find(|entry| entry.action == MenuAction::ShowPairingCode).expect("present").enabled
        };
        assert!(enabled(&hosting));
        assert!(!enabled(&stopped));
    }

    #[test]
    fn settings_can_be_chosen_from_the_menu() {
        let model = MenuModel::new(snapshot(true, RelayStatus::Off, 0));
        let settings = model.entries().into_iter().find(|entry| entry.action == MenuAction::OpenSettings).expect("present");
        assert!(settings.enabled);
    }

    #[test]
    fn the_menu_lists_the_five_entries_in_order() {
        let actions: Vec<MenuAction> =
            MenuModel::new(snapshot(true, RelayStatus::Off, 0)).entries().iter().map(|entry| entry.action).collect();
        assert_eq!(
            actions,
            vec![
                MenuAction::ToggleHosting,
                MenuAction::ShowPairingCode,
                MenuAction::ShowDevices,
                MenuAction::OpenSettings,
                MenuAction::Quit,
            ]
        );
    }

    #[test]
    fn toggling_hosting_asks_the_host_for_the_opposite_state() {
        let hosting = MenuModel::new(snapshot(true, RelayStatus::Off, 0));
        assert_eq!(hosting.command_for(MenuAction::ToggleHosting), Some(RuntimeCommand::SetHosting(false)));
        let stopped = MenuModel::new(snapshot(false, RelayStatus::Off, 0));
        assert_eq!(stopped.command_for(MenuAction::ToggleHosting), Some(RuntimeCommand::SetHosting(true)));
    }

    #[test]
    fn navigation_and_quit_send_no_command() {
        let model = MenuModel::new(snapshot(true, RelayStatus::Off, 0));
        for action in [MenuAction::ShowPairingCode, MenuAction::ShowDevices, MenuAction::OpenSettings, MenuAction::Quit] {
            assert_eq!(model.command_for(action), None);
        }
    }

    #[test]
    fn the_status_line_names_hosting_the_relay_and_the_phones() {
        let model = MenuModel::new(snapshot(true, RelayStatus::Registered, 2));
        assert_eq!(model.status_line(), "Hosting · Relay connected · 2 phones connected");
        let stopped = MenuModel::new(snapshot(false, RelayStatus::Retrying, 0));
        assert_eq!(stopped.status_line(), "Not hosting · Relay retrying · No phone connected");
    }

    #[test]
    fn a_single_phone_is_counted_in_the_singular() {
        assert_eq!(strings::connected_clients(1), "1 phone connected");
    }
}

mod pairing {
    use super::super::*;
    use crate::runtime::{ApprovalView, DeviceView};

    fn offer() -> OfferView {
        OfferView {
            code: "123456".to_owned(),
            client_name: "Pixel 9".to_owned(),
            via_relay: true,
            code_link: "peering://code/123456?s=AB".to_owned(),
        }
    }

    fn snapshot(hosting: bool, offer: Option<OfferView>) -> HostSnapshot {
        HostSnapshot {
            hosting,
            host_link: "peering://host/ID".to_owned(),
            offer,
            ..HostSnapshot::default()
        }
    }

    #[test]
    fn the_panel_says_not_hosting_when_the_host_is_stopped() {
        assert_eq!(UiModel::new(snapshot(false, Some(offer()))).panel(), PairingPanel::NotHosting);
    }

    #[test]
    fn the_panel_shows_the_device_qr_while_no_phone_is_pairing() {
        assert_eq!(
            UiModel::new(snapshot(true, None)).panel(),
            PairingPanel::Ready { host_qr: "peering://host/ID".to_owned() }
        );
    }

    #[test]
    fn the_panel_shows_the_code_and_its_qr_while_a_phone_pairs() {
        assert_eq!(
            UiModel::new(snapshot(true, Some(offer()))).panel(),
            PairingPanel::Pairing {
                code: "123456".to_owned(),
                client_name: "Pixel 9".to_owned(),
                code_qr: "peering://code/123456?s=AB".to_owned(),
                via_relay: true,
            }
        );
    }

    #[test]
    fn each_approval_row_carries_the_command_for_its_own_request() {
        let mut data = snapshot(true, None);
        data.approvals = vec![ApprovalView { id: 4, client_name: "Pixel 9".to_owned() }];
        let rows = UiModel::new(data).approvals();
        assert_eq!(rows.len(), 1);
        assert_eq!(rows[0].approve, RuntimeCommand::Approve(4));
        assert_eq!(rows[0].decline, RuntimeCommand::Decline(4));
        assert_eq!(rows[0].prompt, "Pixel 9 wants to pair without scanning the code");
    }

    #[test]
    fn each_device_row_forgets_its_own_device_and_says_when_it_was_seen() {
        let mut data = snapshot(true, None);
        data.devices = vec![DeviceView { id: "dev-1".to_owned(), name: "Pixel 9".to_owned(), last_seen_unix: 1_000 }];
        let rows = UiModel::new(data).devices(1_000 + 7_200);
        assert_eq!(rows[0].forget, RuntimeCommand::Forget("dev-1".to_owned()));
        assert_eq!(rows[0].last_seen, "Seen 2 h ago");
    }

    #[test]
    fn last_seen_reads_in_seconds_minutes_hours_and_days() {
        assert_eq!(strings::last_seen(5), "Seen just now");
        assert_eq!(strings::last_seen(120), "Seen 2 min ago");
        assert_eq!(strings::last_seen(7_300), "Seen 2 h ago");
        assert_eq!(strings::last_seen(3 * 86_400), "Seen 3 days ago");
    }
}

mod settings {
    use super::super::*;
    use crate::ui::settings::{FirewallOutcome, SettingsChoice, SettingsState};

    fn model_with_rate(frame_rate: u32) -> UiModel {
        UiModel::new(HostSnapshot { frame_rate, ..HostSnapshot::default() })
    }

    #[test]
    fn the_frame_rate_in_force_is_the_selected_choice() {
        let panel = model_with_rate(30).settings(&SettingsState::new(false));
        let selected: Vec<u32> = panel.frame_rates.iter().filter(|choice| choice.selected).map(|choice| choice.fps).collect();
        assert_eq!(selected, vec![30]);
        assert_eq!(panel.frame_rates.iter().map(|choice| choice.fps).collect::<Vec<_>>(), vec![15, 30, 60]);
    }

    #[test]
    fn each_frame_rate_is_labelled_in_frames_per_second() {
        let panel = model_with_rate(60).settings(&SettingsState::new(false));
        assert_eq!(panel.frame_rates[0].label, "15 fps");
        assert_eq!(panel.frame_rates[2].label, "60 fps");
    }

    #[test]
    fn the_start_at_login_box_shows_the_state_the_window_was_given() {
        assert!(model_with_rate(60).settings(&SettingsState::new(true)).start_at_login);
        assert!(!model_with_rate(60).settings(&SettingsState::new(false)).start_at_login);
    }

    #[test]
    fn a_successful_autostart_change_sets_the_box_and_clears_the_note() {
        let mut state = SettingsState::new(false);
        state.record_autostart(true, Err("reg refused".to_owned()));
        assert!(!state.start_at_login());
        assert!(state.autostart_note().is_some_and(|note| note.contains("reg refused")));
        state.record_autostart(true, Ok(()));
        assert!(state.start_at_login());
        assert_eq!(state.autostart_note(), None);
    }

    #[test]
    fn a_failed_autostart_change_leaves_the_box_where_it_was() {
        let mut state = SettingsState::new(true);
        state.record_autostart(false, Err("access denied".to_owned()));
        assert!(state.start_at_login());
        assert!(state.autostart_note().is_some());
    }

    #[test]
    fn no_firewall_text_shows_before_the_first_request() {
        assert_eq!(model_with_rate(60).settings(&SettingsState::new(false)).firewall_note, None);
    }

    #[test]
    fn the_firewall_result_is_shown_as_requested_or_refused() {
        let mut state = SettingsState::new(false);
        state.record_firewall(FirewallOutcome::Requested);
        assert_eq!(model_with_rate(60).settings(&state).firewall_note.as_deref(), Some(strings::FIREWALL_REQUESTED));
        state.record_firewall(FirewallOutcome::Refused("the prompt was declined".to_owned()));
        let note = model_with_rate(60).settings(&state).firewall_note.expect("a refusal is shown");
        assert!(note.contains("the prompt was declined"));
    }

    #[test]
    fn only_a_frame_rate_choice_becomes_a_host_command() {
        assert_eq!(settings_command(&SettingsChoice::FrameRate(30)), Some(RuntimeCommand::SetFrameRate(30)));
        assert_eq!(settings_command(&SettingsChoice::StartAtLogin(true)), None);
        assert_eq!(settings_command(&SettingsChoice::FixFirewall), None);
    }
}
