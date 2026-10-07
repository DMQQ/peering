#if DEBUG
import Foundation
import MacCastKit
import RemoteCore

/// A finished-looking chat for the App Store capture, switched on by `-Peering.seedAgentChat 1`.
enum AgentSeed {
    static var isRequested: Bool {
        UserDefaults.standard.bool(forKey: "Peering.seedAgentChat") || ProcessInfo.processInfo.environment["PEERING_SEED_AGENT_CHAT"] == "1"
    }

    private static let id = UUID(uuidString: "5EED0000-0000-4000-8000-000000000001")!

    static func owns(_ candidate: UUID) -> Bool { candidate == id || candidate.uuidString.hasPrefix("5EED0000-0000-4000-8000-") }

    static func sessions() -> [RemoteAgentSession] {
        if let scenario = AgentSeedScenario.requested { return scenarioSessions(scenario) }
        let info = AgentSessionInfo(
            id: id,
            agentID: "claude",
            title: "Claude Code · orders-service",
            directory: "/Users/demo/orders-service",
            state: .awaitingApproval,
            lastIndex: 0,
            model: "Opus 5.5",
            permissionMode: .manual,
            permissionModes: [.manual, .acceptEdits, .auto],
            usage: AgentUsage(
                contextUsedTokens: 38_400, contextWindowTokens: 200_000,
                inputTokens: 21_300, cachedTokens: 96_000, outputTokens: 3_900, costUSD: 0.41,
                limits: [AgentUsageLimit(label: "5 hours", usedFraction: 0.28, resetsAt: .now + 3 * 3_600)]
            ),
            createdAt: .now - 600
        )
        var session = RemoteAgentSession(info)
        session.transcript.apply(events)
        session.isLoaded = true
        return [session]
    }

    private static func call(_ id: String, _ name: String, _ title: String, detail: String? = nil, diff: String? = nil, plan: [AgentPlanStep]? = nil) -> AgentToolCall {
        AgentToolCall(id: id, name: name, title: title, detail: detail, filePath: nil, diff: diff, plan: plan)
    }

    private static let plan: [AgentPlanStep] = [
        .init(text: "Read the pricing code", status: .completed),
        .init(text: "Add a 10% discount over $100", status: .completed),
        .init(text: "Cover it with tests", status: .completed),
        .init(text: "Run the test suite", status: .inProgress),
    ]

    private static var events: [AgentStreamEvent] {
        let diff = """
        --- a/src/models/pricing.ts
        +++ b/src/models/pricing.ts
        @@ -1 +1,6 @@
        -export const sumOf = (items: { price: number; qty: number }[]) => items.reduce((s, i) => s + i.price * i.qty, 0);
        +const DISCOUNT_THRESHOLD = 100;
        +const DISCOUNT_RATE = 0.1;
        +
        +export const sumOf = (items: { price: number; qty: number }[]) => {
        +  const gross = items.reduce((s, i) => s + i.price * i.qty, 0);
        +  return gross > DISCOUNT_THRESHOLD ? gross * (1 - DISCOUNT_RATE) : gross;
        +};
        """
        let payloads: [AgentStreamEvent.Payload] = [
            .userPrompt(text: "Give orders over $100 a 10% discount and add a test for it."),
            .turnStarted,
            .toolStarted(call: call("t1", "Read", "Read pricing.ts", detail: "src/models/pricing.ts")),
            .toolFinished(callID: "t1", ok: true, output: nil, truncated: false),
            .textFinal(text: "Totals are computed in one place, `sumOf`, so the discount belongs there and every route picks it up."),
            .toolStarted(call: call("t2", "TodoWrite", "Updated the plan", plan: plan)),
            .toolFinished(callID: "t2", ok: true, output: nil, truncated: false),
            .toolStarted(call: call("t3", "Edit", "Edited pricing.ts", detail: "src/models/pricing.ts", diff: diff)),
            .toolFinished(callID: "t3", ok: true, output: nil, truncated: false),
            .toolStarted(call: call("t4", "Edit", "Edited orders.test.ts", detail: "tests/orders.test.ts")),
            .toolFinished(callID: "t4", ok: true, output: nil, truncated: false),
            .textFinal(text: "The discount is in and covered by two new cases: an order just under $100 and one just over. Running the suite to confirm."),
            .approvalRequested(approvalID: "a1", call: call("t5", "Bash", "Run npm test", detail: "npm test"), reason: nil),
        ]
        return payloads.enumerated().map { AgentStreamEvent(index: UInt64($0.offset + 1), payload: $0.element) }
    }
}
#endif
