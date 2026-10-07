import Foundation
import RemoteCore

/// Follows one session's turn through its events and says what is worth reporting when a turn or tool call ends.
struct AgentTurnTelemetry {
    enum Emission {
        case tool(run: AIAssistantAnalytics.ToolRun, ok: Bool, output: String?, truncated: Bool)
        case generation(turn: AIAssistantAnalytics.Turn, summary: AgentTurnSummary, model: String?)
        case failedGeneration(turn: AIAssistantAnalytics.Turn, model: String?)
    }

    private var turn: AIAssistantAnalytics.Turn?
    private var toolRuns: [String: AIAssistantAnalytics.ToolRun] = [:]

    mutating func record(_ payload: AgentStreamEvent.Payload, model: String?) -> Emission? {
        switch payload {
        case .userPrompt(let text):
            // A prompt sent mid-turn belongs to the turn already running, which a second one would overwrite and lose.
            if turn == nil {
                turn = AIAssistantAnalytics.Turn(input: text)
                toolRuns.removeAll()
            } else {
                turn?.input += "\n\n" + text
            }
        case .textFinal(let text):
            turn?.outputParts.append(text)
        case .toolStarted(let call):
            if let traceID = turn?.traceID {
                toolRuns[call.id] = AIAssistantAnalytics.ToolRun(traceID: traceID, call: call)
            }
        case .toolFinished(let callID, let ok, let output, let truncated):
            if let run = toolRuns.removeValue(forKey: callID) {
                return .tool(run: run, ok: ok, output: output, truncated: truncated)
            }
        case .turnFinished(let summary):
            guard let finished = end() else { return nil }
            return .generation(turn: finished, summary: summary, model: summary.model ?? model)
        case .failure, .sessionExited:
            guard let failed = end() else { return nil }
            return .failedGeneration(turn: failed, model: model)
        default:
            break
        }
        return nil
    }

    private mutating func end() -> AIAssistantAnalytics.Turn? {
        defer {
            turn = nil
            toolRuns.removeAll()
        }
        return turn
    }

    static func send(_ emission: Emission, agentID: String, sessionID: UUID) {
        switch emission {
        case .tool(let run, let ok, let output, let truncated):
            AIAssistantAnalytics.captureTool(
                agentID: agentID, sessionID: sessionID, run: run, ok: ok, output: output, truncated: truncated
            )
        case .generation(let turn, let summary, let model):
            AIAssistantAnalytics.captureGeneration(
                agentID: agentID, sessionID: sessionID, turn: turn, summary: summary, model: model
            )
        case .failedGeneration(let turn, let model):
            AIAssistantAnalytics.captureFailedGeneration(
                agentID: agentID, sessionID: sessionID, turn: turn, model: model
            )
        }
    }
}
