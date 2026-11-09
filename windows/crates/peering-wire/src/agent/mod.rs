//! Agent chat wire models, shaped as the Swift `Codable` output in `AgentWire.swift`. See docs/protocol.md section 7.

mod changes;
mod event;
mod request;
mod routine;
mod session;
mod stream;
mod tool;

#[cfg(test)]
mod tests;

pub use changes::{
    is_inside_folder, AgentChangeKind, AgentChangedFile, AgentChangesReport, AgentGitBranch, AgentGitOperation,
    AgentGitResult,
};
pub use event::AgentEvent;
pub use request::AgentRequest;
pub use routine::{AgentRoutine, AgentRoutineOutcome, AgentRoutineRun, AgentRoutineSchedule};
pub use session::{AgentPermissionMode, AgentSessionInfo, AgentSessionState, AgentUsage, AgentUsageLimit};
pub use stream::{AgentStreamEvent, AgentStreamPayload};
pub use tool::{
    AgentApprovalDecision, AgentPlanStep, AgentPlanStepStatus, AgentQuestion, AgentToolCall, AgentToolOption,
    AgentTurnSummary,
};
