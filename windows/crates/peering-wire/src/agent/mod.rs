//! Agent chat wire models, shaped as the Swift `Codable` output in `AgentWire.swift`. See docs/protocol.md section 7.

mod event;
mod request;
mod session;
mod stream;
mod tool;

#[cfg(test)]
mod tests;

pub use event::AgentEvent;
pub use request::AgentRequest;
pub use session::{AgentPermissionMode, AgentSessionInfo, AgentSessionState, AgentUsage, AgentUsageLimit};
pub use stream::{AgentStreamEvent, AgentStreamPayload};
pub use tool::{
    AgentApprovalDecision, AgentPlanStep, AgentPlanStepStatus, AgentQuestion, AgentToolCall, AgentToolOption,
    AgentTurnSummary,
};
