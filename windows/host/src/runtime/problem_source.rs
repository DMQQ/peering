//! The parts of the host that can have something wrong with them, each showing at most one problem in the window until it
//! recovers.

#[derive(Debug, Clone, Copy, PartialEq, Eq, PartialOrd, Ord)]
pub enum ProblemSource {
    Video,
    Terminals,
    Agents,
    Pointer,
    Relay,
    /// The relay refused the registration because this PC's clock is off.
    RelayClock,
    PairedDevices,
}
