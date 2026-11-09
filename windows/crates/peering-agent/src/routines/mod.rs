//! Agent routines: a prompt the host sends to an agent on a schedule, in a chat of its own, while the phone is away.
//! Mirrors `PeeringHost/Agent/Routines` and the `AgentRoutine*` types of `PeeringKit`.

mod plan;
mod progress;
mod requests;
mod scheduler;
mod storage;
mod validation;

#[cfg(test)]
mod tests;

pub use plan::{is_due, next_fire, FixedOffset, UtcOffset};
pub use progress::{progress_of, RoutineProgress};
pub use scheduler::{ChatStatus, RoutineChats, RoutineEnvironment, RoutineScheduler, ROUTINES_PER_CLIENT};
pub use storage::{MemoryRoutineStorage, RoutineEntry, RoutineStorage};
pub use validation::{problem_with, RoutineProblem};
