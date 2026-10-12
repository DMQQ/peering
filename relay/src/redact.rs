//! Short stand-ins for identifiers in the journal.
//!
//! The relay is meant to be unable to read what it carries, and its log is not the place to undo
//! that. An identifier that has to appear (so lines about one client can be read together) goes
//! through [`tag`]: a keyed hash under a key drawn at startup and kept only in memory. Lines for one
//! client agree within a run, cannot be walked back to the identifier, and cannot be matched
//! against a list of known ids or against another run's lines.

use std::collections::hash_map::RandomState;
use std::fmt;
use std::hash::BuildHasher;
use std::sync::OnceLock;

/// Eight hex characters of a keyed hash.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub struct Tag(u32);

impl fmt::Display for Tag {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        write!(f, "{:08x}", self.0)
    }
}

/// A hasher with its own key, so tests can have more than one.
pub struct Redactor {
    key: RandomState,
}

impl Redactor {
    pub fn new() -> Self {
        Self { key: RandomState::new() }
    }

    pub fn tag(&self, identifier: &str) -> Tag {
        Tag(self.key.hash_one(identifier) as u32)
    }
}

impl Default for Redactor {
    fn default() -> Self {
        Self::new()
    }
}

/// The process-wide redactor, keyed on first use.
pub fn tag(identifier: &str) -> Tag {
    static PROCESS: OnceLock<Redactor> = OnceLock::new();
    PROCESS.get_or_init(Redactor::new).tag(identifier)
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn a_tag_is_eight_lowercase_hex_characters_and_does_not_contain_its_input() {
        let shown = Redactor::new().tag("0f3a9c1e-device").to_string();
        assert_eq!(shown.len(), 8);
        assert!(shown.chars().all(|c| c.is_ascii_hexdigit() && !c.is_ascii_uppercase()));
        assert!(!"0f3a9c1e-device".contains(&shown));
    }

    #[test]
    fn one_identifier_keeps_one_tag_within_a_run_and_two_identifiers_get_two() {
        let redactor = Redactor::new();
        assert_eq!(redactor.tag("phone-a"), redactor.tag("phone-a"));
        assert_ne!(redactor.tag("phone-a"), redactor.tag("phone-b"));
        assert_eq!(tag("phone-a"), tag("phone-a"));
    }

    #[test]
    fn two_runs_disagree_about_the_same_identifier() {
        // Each redactor draws its own key, as each process does. A 32 bit tag collides by chance
        // once in four billion; compare several so a chance collision cannot fail this.
        let (one, two) = (Redactor::new(), Redactor::new());
        let agreeing = (0..8).filter(|n| one.tag(&format!("id-{n}")) == two.tag(&format!("id-{n}"))).count();
        assert!(agreeing < 8, "tags from different keys should not line up");
    }
}
