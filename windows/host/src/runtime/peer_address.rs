//! The one signalling socket to the relay carries every video lane's `requestPeerAddress`, and the answers come back on
//! it without naming who asked. Answers are matched to asks in the order they were sent.

use std::collections::VecDeque;
use std::net::{IpAddr, SocketAddr};

use peering_wire::relay_messages::{RelayClientMessage, Token};

use super::ask_queue::{ask_channel, AskReceiver, AskSender};

const MAXIMUM_WAITING: usize = 16;
/// Asks the signalling socket has not written yet. A lane asks again later, so an old ask that never went out is dropped.
pub const ASK_QUEUE_DEPTH: usize = MAXIMUM_WAITING;
/// Answers a lane has not read yet. A lane asks one question at a time.
pub const ANSWER_QUEUE_DEPTH: usize = 4;

/// The queue the signalling socket reads its asks from.
pub fn signalling_channel() -> (AskSender<RelayClientMessage>, AskReceiver<RelayClientMessage>) {
    ask_channel(ASK_QUEUE_DEPTH)
}

/// The queue a lane reads its answers from.
pub fn answer_channel() -> (AskSender<SocketAddr>, AskReceiver<SocketAddr>) {
    ask_channel(ANSWER_QUEUE_DEPTH)
}

#[derive(Default)]
pub struct PeerAddressRouter {
    outbound: Option<AskSender<RelayClientMessage>>,
    waiting: VecDeque<AskSender<SocketAddr>>,
}

impl PeerAddressRouter {
    /// Attaches a signalling socket, or detaches it with `None`. A new socket starts with no asks waiting, because the
    /// relay never answers across a reconnect.
    pub fn attach(&mut self, outbound: Option<AskSender<RelayClientMessage>>) {
        self.outbound = outbound;
        self.waiting.clear();
    }

    /// Sends the ask for `token`'s peer and queues `answer_to` for the reply. False when no signalling socket is open.
    pub fn ask(&mut self, token: [u8; 16], answer_to: AskSender<SocketAddr>) -> bool {
        let Some(outbound) = self.outbound.as_ref() else {
            return false;
        };
        let message = RelayClientMessage::RequestPeerAddress { video_token: Token(token).to_hex() };
        if outbound.send(message).is_err() {
            return false;
        }
        self.waiting.push_back(answer_to);
        while self.waiting.len() > MAXIMUM_WAITING {
            self.waiting.pop_front();
        }
        true
    }

    /// A `peerAddress` answers the oldest ask.
    pub fn answer(&mut self, address: SocketAddr) {
        if let Some(asker) = self.waiting.pop_front() {
            // The lane that asked has ended when this fails; its answer has nowhere to go.
            let _delivered = asker.send(address);
        }
    }

    /// A `peerAddressUnknown` answers the oldest ask with nothing, and that lane asks again later.
    pub fn refuse(&mut self) {
        self.waiting.pop_front();
    }
}

/// The address the relay reported. Only a literal IP is accepted: the relay hands over literals, and a name would need
/// a resolver call on the socket task.
pub fn peer_socket_addr(host: &str, port: u16) -> Option<SocketAddr> {
    let address: IpAddr = host.parse().ok()?;
    (port != 0).then(|| SocketAddr::new(address, port))
}

#[cfg(test)]
mod tests {
    use super::*;
    
    #[test]
    fn an_ip_literal_and_a_port_make_a_peer_address() {
        assert_eq!(peer_socket_addr("203.0.113.7", 40000), Some("203.0.113.7:40000".parse().unwrap()));
        assert_eq!(peer_socket_addr("2001:db8::1", 40000), Some("[2001:db8::1]:40000".parse().unwrap()));
    }

    #[test]
    fn a_name_or_a_zero_port_is_not_a_peer_address() {
        assert_eq!(peer_socket_addr("phone.example", 40000), None);
        assert_eq!(peer_socket_addr("203.0.113.7", 0), None);
    }

    #[test]
    fn an_ask_without_a_signalling_socket_is_not_sent() {
        let mut router = PeerAddressRouter::default();
        let (answers, _receiver) = answer_channel();
        assert!(!router.ask([1; 16], answers));
    }

    #[test]
    fn an_ask_carries_the_token_as_hex_and_its_answer_comes_back_to_the_asker() {
        let mut router = PeerAddressRouter::default();
        let (signalling, mut sent) = signalling_channel();
        router.attach(Some(signalling));
        let (answers, mut answered) = answer_channel();
        assert!(router.ask([0xab; 16], answers));
        assert_eq!(
            sent.try_recv(),
            Some(RelayClientMessage::RequestPeerAddress { video_token: "ab".repeat(16) })
        );
        let address: SocketAddr = "198.51.100.2:5000".parse().unwrap();
        router.answer(address);
        assert_eq!(answered.try_recv(), Some(address));
    }

    #[test]
    fn answers_go_to_asks_in_the_order_they_were_sent() {
        let mut router = PeerAddressRouter::default();
        let (signalling, _sent) = signalling_channel();
        router.attach(Some(signalling));
        let (first, mut first_answers) = answer_channel();
        let (second, mut second_answers) = answer_channel();
        router.ask([1; 16], first);
        router.ask([2; 16], second);
        router.refuse();
        let address: SocketAddr = "198.51.100.3:6000".parse().unwrap();
        router.answer(address);
        assert_eq!(first_answers.try_recv(), None);
        assert_eq!(second_answers.try_recv(), Some(address));
    }

    #[test]
    fn a_new_signalling_socket_forgets_the_asks_of_the_old_one() {
        let mut router = PeerAddressRouter::default();
        let (signalling, _sent) = signalling_channel();
        router.attach(Some(signalling));
        let (answers, mut answered) = answer_channel();
        router.ask([1; 16], answers);
        router.attach(None);
        router.answer("198.51.100.4:7000".parse().unwrap());
        assert_eq!(answered.try_recv(), None);
    }
}
