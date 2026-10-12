import Foundation
import MacCastKit
import RemoteCore

/// Turns what the planner decided into the relay message, using the state types the widget decodes.
///
/// The state is coded: no Mac name, chat title, folder or reply is in it. The card reads those from the App Group store by `hostKey` and chat id.
enum LiveActivityPushBuilder {
    /// Fixed sentences for the alert a start, approval or finish carries. Apple and the relay see these and nothing the person typed.
    struct AlertText: Equatable {
        var title: String
        var body: String
    }

    static let agentChatAttributesType = "AgentChatActivityAttributes"

    static func push(for command: LiveActivityCommand, hostID: String, now: Date) throws -> RelayActivityPush {
        let hostKey = HostKey.of(hostID)
        let state: RelayJSON
        switch command.kind {
        case .session:
            state = try json(sessionState(command.truth, hostKey: hostKey))
        case .agentChat:
            state = try json(agentChatState(command.truth, hostKey: hostKey, now: now))
        }
        let isStart = command.event == .start
        let text = command.alert.map(alertText)
        return RelayActivityPush(
            activityToken: command.token,
            activity: command.kind,
            event: relayEvent(command.event),
            contentState: state,
            priority: command.priority,
            attributesType: isStart ? agentChatAttributesType : nil,
            attributes: isStart ? .object(["origin": .string("host")]) : nil,
            alertTitle: text?.title,
            alertBody: text?.body,
            environment: command.environment
        )
    }

    static func sessionState(_ truth: LiveActivityTruth, hostKey: String) -> SessionActivityState {
        SessionActivityState(
            phase: truth.phase == .active ? .active : .dropped,
            startedAt: truth.startedAt,
            path: path(truth.path),
            hostName: nil,
            sessionCount: nil,
            work: work(truth.chats),
            hostKey: hostKey
        )
    }

    static func agentChatState(_ truth: LiveActivityTruth, hostKey: String, now: Date) -> AgentChatActivityState {
        let top = truth.topChat
        return AgentChatActivityState(
            chat: AgentChatSnapshot(
                id: top?.id ?? "",
                hostID: nil,
                title: "",
                symbol: top?.symbol ?? "sparkles",
                folder: "",
                state: chatState(top?.state ?? .finished),
                activity: nil,
                planDone: 0,
                planTotal: 0,
                planStepNumber: nil,
                planStep: nil,
                updatedAt: now
            ),
            waiting: truth.waitingCount,
            working: truth.workingCount,
            hostKey: hostKey
        )
    }

    static func alertText(_ alert: LiveActivityCommand.Alert) -> AlertText {
        switch alert {
        case .needsApproval:
            AlertText(
                title: String(localized: "An agent needs you"),
                body: String(localized: "A coding agent is waiting for your approval.")
            )
        case .finished:
            AlertText(
                title: String(localized: "An agent finished"),
                body: String(localized: "A coding agent has finished its work.")
            )
        case .failed:
            AlertText(
                title: String(localized: "An agent stopped"),
                body: String(localized: "A coding agent stopped with an error.")
            )
        }
    }

    /// A default encoder on purpose: ActivityKit decodes a push with default strategies, so a Date travels as seconds since 2001.
    private static func json(_ value: some Encodable) throws -> RelayJSON {
        try JSONDecoder().decode(RelayJSON.self, from: JSONEncoder().encode(value))
    }

    private static func work(_ chats: [LiveActivityChat]) -> [SessionActivityState.Work]? {
        let rows = chats.compactMap { chat -> SessionActivityState.Work? in
            switch chat.state {
            case .needsYou: .init(name: "", symbol: "questionmark.bubble", state: .waiting, detail: nil)
            case .working: .init(name: "", symbol: chat.symbol, state: .live, detail: nil)
            case .failed: .init(name: "", symbol: "exclamationmark.triangle", state: .failed, detail: nil)
            case .finished: nil
            }
        }
        .sorted { $0.state.isWaiting && !$1.state.isWaiting }
        return rows.isEmpty ? nil : Array(rows.prefix(4))
    }

    private static func chatState(_ state: LiveActivityChat.State) -> AgentChatSnapshot.State {
        switch state {
        case .needsYou: .needsYou
        case .working: .working
        case .failed: .failed
        case .finished: .finished
        }
    }

    private static func path(_ path: LiveActivityPath) -> SessionActivityState.Path {
        switch path {
        case .lan: .lan
        case .relay: .relay
        case .direct: .direct
        }
    }

    private static func relayEvent(_ event: LiveActivityCommand.Event) -> RelayActivityEvent {
        switch event {
        case .start: .start
        case .update: .update
        case .end: .end
        }
    }
}
