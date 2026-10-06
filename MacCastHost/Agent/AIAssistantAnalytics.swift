import Foundation
import PostHog
import RemoteCore

/// AI Observability for the normalized events emitted by externally managed agent CLIs.
enum AIAssistantAnalytics {
    static let privacyMode = true

    struct Turn {
        let traceID = UUID().uuidString
        let input: String
        let startedAt = Date()
        var outputParts: [String] = []
    }

    struct ToolRun {
        let traceID: String
        let startedAt = Date()
        let call: AgentToolCall
    }

    static func captureGeneration(
        agentID: String,
        sessionID: UUID,
        turn: Turn,
        summary: AgentTurnSummary,
        model: String?
    ) {
        guard PostHogConfiguration.isConfigured else { return }
        var properties = generationProperties(
            agentID: agentID,
            sessionID: sessionID,
            traceID: turn.traceID,
            model: model,
            inputTokens: summary.inputTokens,
            outputTokens: summary.outputTokens,
            latency: summary.duration ?? Date().timeIntervalSince(turn.startedAt),
            isError: !summary.ok
        )
        if !privacyMode {
            properties["$ai_input"] = [["role": "user", "content": turn.input]]
            properties["$ai_output_choices"] = turn.outputParts.map { ["role": "assistant", "content": $0] }
        }
        PostHogSDK.shared.capture("$ai_generation", properties: properties)
    }

    static func captureFailedGeneration(
        agentID: String,
        sessionID: UUID,
        turn: Turn,
        model: String?
    ) {
        guard PostHogConfiguration.isConfigured else { return }
        var properties = generationProperties(
            agentID: agentID,
            sessionID: sessionID,
            traceID: turn.traceID,
            model: model,
            inputTokens: nil,
            outputTokens: nil,
            latency: Date().timeIntervalSince(turn.startedAt),
            isError: true
        )
        if !privacyMode {
            properties["$ai_input"] = [["role": "user", "content": turn.input]]
            properties["$ai_output_choices"] = turn.outputParts.map { ["role": "assistant", "content": $0] }
        }
        PostHogSDK.shared.capture("$ai_generation", properties: properties)
    }

    static func captureTool(
        agentID: String,
        sessionID: UUID,
        run: ToolRun,
        ok: Bool,
        output: String?,
        truncated: Bool
    ) {
        guard PostHogConfiguration.isConfigured else { return }
        var properties: [String: Any] = [
            "$ai_session_id": sessionID.uuidString,
            "$ai_trace_id": run.traceID,
            "$ai_span_id": run.call.id,
            "$ai_span_name": run.call.name,
            "$ai_span_kind": "tool",
            "$ai_latency": Date().timeIntervalSince(run.startedAt),
            "$ai_is_error": !ok,
            "agent": agentID,
            "truncated": truncated,
        ]
        if !privacyMode {
            properties["$ai_input"] = ["name": run.call.name, "detail": run.call.detail ?? ""]
            if let output { properties["$ai_output"] = output }
        }
        PostHogSDK.shared.capture("$ai_span", properties: properties)
    }

    private static func generationProperties(
        agentID: String,
        sessionID: UUID,
        traceID: String,
        model: String?,
        inputTokens: Int?,
        outputTokens: Int?,
        latency: TimeInterval,
        isError: Bool
    ) -> [String: Any] {
        var properties: [String: Any] = [
            "$ai_session_id": sessionID.uuidString,
            "$ai_trace_id": traceID,
            "$ai_model": model ?? "unknown",
            "$ai_latency": latency,
            "$ai_is_error": isError,
            "agent": agentID,
        ]
        if let provider = provider(for: agentID) { properties["$ai_provider"] = provider }
        if let inputTokens { properties["$ai_input_tokens"] = inputTokens }
        if let outputTokens { properties["$ai_output_tokens"] = outputTokens }
        return properties
    }

    private static func provider(for agentID: String) -> String? {
        switch agentID {
        case "claude": "anthropic"
        case "codex": "openai"
        default: nil
        }
    }
}
