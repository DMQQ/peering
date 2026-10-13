//! Whether the agent CLI is installed on this PC, so the host advertises chat only when a chat could start. The answer is
//! cached, because a hello is answered on every connection and a search through `PATH` touches the disk.

/// Where the question "is this program installed" is answered. Real code looks on disk; tests answer from a set.
pub trait BinaryLocator {
    fn is_installed(&self, program: &str) -> bool;
}

/// A missing CLI is looked for again after this long, so installing it is noticed by the next connection.
pub const RECHECK_MISSING_SECONDS: f64 = 10.0;
/// A found CLI is looked for again after this long, so uninstalling it is noticed eventually.
pub const RECHECK_FOUND_SECONDS: f64 = 300.0;

pub struct AgentAvailability {
    locator: Box<dyn BinaryLocator>,
    program: &'static str,
    checked: Option<(f64, bool)>,
}

impl AgentAvailability {
    pub fn new(locator: Box<dyn BinaryLocator>, program: &'static str) -> Self {
        Self { locator, program, checked: None }
    }

    /// Looks now, whatever the cache holds.
    pub fn check(&mut self, now: f64) -> bool {
        let installed = self.locator.is_installed(self.program);
        self.checked = Some((now, installed));
        installed
    }

    /// The cached answer, looked up again when it is old enough or has never been looked up.
    pub fn installed(&mut self, now: f64) -> bool {
        match self.checked {
            Some((at, installed)) if now - at < Self::recheck_after(installed) => installed,
            _ => self.check(now),
        }
    }

    fn recheck_after(installed: bool) -> f64 {
        if installed {
            RECHECK_FOUND_SECONDS
        } else {
            RECHECK_MISSING_SECONDS
        }
    }
}

#[cfg(test)]
mod tests {
    use std::cell::Cell;
    use std::rc::Rc;

    use super::*;

    struct Fake {
        installed: Rc<Cell<bool>>,
        lookups: Rc<Cell<u32>>,
    }

    impl BinaryLocator for Fake {
        fn is_installed(&self, _program: &str) -> bool {
            self.lookups.set(self.lookups.get() + 1);
            self.installed.get()
        }
    }

    fn availability(installed: bool) -> (AgentAvailability, Rc<Cell<bool>>, Rc<Cell<u32>>) {
        let installed = Rc::new(Cell::new(installed));
        let lookups = Rc::new(Cell::new(0));
        let fake = Fake { installed: installed.clone(), lookups: lookups.clone() };
        (AgentAvailability::new(Box::new(fake), "claude"), installed, lookups)
    }

    #[test]
    fn a_found_cli_is_remembered_between_hellos() {
        let (mut availability, _installed, lookups) = availability(true);
        assert!(availability.installed(0.0));
        assert!(availability.installed(299.0));
        assert_eq!(lookups.get(), 1);
        assert!(availability.installed(300.0));
        assert_eq!(lookups.get(), 2);
    }

    #[test]
    fn a_missing_cli_is_looked_for_again_soon_so_an_install_is_noticed() {
        let (mut availability, installed, lookups) = availability(false);
        assert!(!availability.installed(0.0));
        assert!(!availability.installed(9.0));
        assert_eq!(lookups.get(), 1);
        installed.set(true);
        assert!(availability.installed(10.0));
    }

    #[test]
    fn a_check_on_demand_ignores_the_cache() {
        let (mut availability, installed, _lookups) = availability(true);
        assert!(availability.installed(0.0));
        installed.set(false);
        assert!(availability.installed(1.0), "still cached");
        assert!(!availability.check(1.0));
        assert!(!availability.installed(2.0));
    }
}
