//! Relay fixtures shared by the relay and video flows.


pub const RELAY_TOKEN_HEX: &str = "00112233445566778899aabbccddeeff";

pub fn relay_token() -> peering_wire::relay_messages::Token {
    peering_wire::relay_messages::Token::parse(RELAY_TOKEN_HEX).expect("a 32 digit token")
}

