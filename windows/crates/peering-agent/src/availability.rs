//! Which agent CLIs are installed on this PC, so the host advertises chat only with agents a chat could start in. Answers
//! are cached, because a hello is answered on every connection and a search through `PATH` touches the disk.

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
    programs: Vec<&'static str>,
    checked: Vec<Option<(f64, bool)>>,
}

impl AgentAvailability {
    pub fn new(locator: Box<dyn BinaryLocator>, programs: &[&'static str]) -> Self {
        Self { locator, programs: programs.to_vec(), checked: vec![None; programs.len()] }
    }

    /// Looks now for every program, whatever the cache holds. True when any is installed.
    pub fn check(&mut self, now: f64) -> bool {
        let found: Vec<bool> = (0..self.programs.len()).map(|index| self.look(index, now)).collect();
        found.contains(&true)
    }

    /// The installed programs, in the order they were given. Each is looked up again when its answer is old enough.
    pub fn installed_programs(&mut self, now: f64) -> Vec<String> {
        let installed: Vec<usize> = (0..self.programs.len())
            .filter(|&index| match self.checked[index] {
                Some((at, installed)) if now - at < Self::recheck_after(installed) => installed,
                _ => self.look(index, now),
            })
            .collect();
        installed.into_iter().map(|index| self.programs[index].to_owned()).collect()
    }

    fn look(&mut self, index: usize, now: f64) -> bool {
        let installed = self.locator.is_installed(self.programs[index]);
        self.checked[index] = Some((now, installed));
        installed
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
        (AgentAvailability::new(Box::new(fake), &["claude"]), installed, lookups)
    }

    #[test]
    fn a_found_cli_is_remembered_between_hellos() {
        let (mut availability, _installed, lookups) = availability(true);
        assert!(!availability.installed_programs(0.0).is_empty());
        assert!(!availability.installed_programs(299.0).is_empty());
        assert_eq!(lookups.get(), 1);
        assert!(!availability.installed_programs(300.0).is_empty());
        assert_eq!(lookups.get(), 2);
    }

    #[test]
    fn a_missing_cli_is_looked_for_again_soon_so_an_install_is_noticed() {
        let (mut availability, installed, lookups) = availability(false);
        assert!(availability.installed_programs(0.0).is_empty());
        assert!(availability.installed_programs(9.0).is_empty());
        assert_eq!(lookups.get(), 1);
        installed.set(true);
        assert!(!availability.installed_programs(10.0).is_empty());
    }

    struct OnlyCodex;

    impl BinaryLocator for OnlyCodex {
        fn is_installed(&self, program: &str) -> bool {
            program == "codex"
        }
    }

    #[test]
    fn only_the_installed_agents_are_listed() {
        let mut availability = AgentAvailability::new(Box::new(OnlyCodex), &["claude", "codex", "opencode"]);
        assert_eq!(availability.installed_programs(0.0), ["codex"]);
    }

    #[test]
    fn a_check_on_demand_ignores_the_cache() {
        let (mut availability, installed, _lookups) = availability(true);
        assert!(!availability.installed_programs(0.0).is_empty());
        installed.set(false);
        assert!(!availability.installed_programs(1.0).is_empty(), "still cached");
        assert!(!availability.check(1.0));
        assert!(availability.installed_programs(2.0).is_empty());
    }
}
