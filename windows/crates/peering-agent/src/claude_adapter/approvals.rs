//! Answers to the CLI's `can_use_tool` requests.

use super::ClaudeAdapter;
use peering_wire::agent::AgentApprovalDecision;
use serde_json::{json, Map, Value};

impl ClaudeAdapter {
    /// Answers the ask `approval_id`. Returns false when the process did not take the answer.
    pub fn respond(&mut self, approval_id: &str, decision: &AgentApprovalDecision) -> bool {
        // The CLI wants its tool input echoed back on an allow. After a restart the input is gone, and the
        // answer carries an empty one.
        let input = self.stream.take_approval_input(approval_id).unwrap_or_default();
        let body = approval_body(input, decision);
        let sent = self.send(&json!({
            "type": "control_response",
            "response": {"subtype": "success", "request_id": approval_id, "response": body},
        }));
        let was_plan = self.plan_approvals.remove(approval_id);
        // Approving a plan ends plan mode, and the CLI does not say what it falls back to.
        if sent && was_plan && matches!(decision, AgentApprovalDecision::Allow {}) {
            self.apply_mode(self.mode_before_plan);
        }
        sent
    }
}

fn approval_body(input: Map<String, Value>, decision: &AgentApprovalDecision) -> Value {
    match decision {
        AgentApprovalDecision::Allow {} => json!({"behavior": "allow", "updatedInput": input}),
        AgentApprovalDecision::Deny {} => json!({"behavior": "deny", "message": "Denied from Peering."}),
        AgentApprovalDecision::Choose { answers } => {
            json!({"behavior": "allow", "updatedInput": with_answers(input, answers)})
        }
    }
}

/// A question ask is answered by an allow whose input carries the answers keyed by question text. Any other
/// answer makes the CLI ask the question again.
fn with_answers(mut input: Map<String, Value>, labels: &[String]) -> Map<String, Value> {
    let Some(questions) = input.get("questions").and_then(Value::as_array) else {
        return input;
    };
    let answers: Map<String, Value> = questions
        .iter()
        .zip(labels)
        .filter_map(|(entry, label)| {
            let question = entry.get("question")?.as_str()?;
            Some((question.to_owned(), Value::String(label.clone())))
        })
        .collect();
    input.insert("answers".to_owned(), Value::Object(answers));
    input
}
