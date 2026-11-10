import ActivityKit
import SwiftUI
import WidgetKit

/// Open this file in Xcode and use the canvas: each preview steps through its states with the arrows under the device, and the same three activities appear on the Lock Screen and in each Dynamic Island size.

private enum PreviewFixture {
    static func minutesAgo(_ minutes: Double) -> Date { Date().addingTimeInterval(-minutes * 60) }

    static func session(_ phase: SessionActivityState.Phase, path: SessionActivityState.Path? = .lan, minutes: Double? = 31, macs: Int? = nil, work: [SessionActivityState.Work]? = nil) -> SessionActivityState {
        SessionActivityState(phase: phase, startedAt: minutes.map(minutesAgo), path: path, hostName: "Damian's MacBook Pro", sessionCount: macs, work: work, hostKey: nil)
    }

    static let work: [SessionActivityState.Work] = [
        .init(name: "Peering", symbol: "sparkles", state: .waiting, detail: "Approve a command"),
        .init(name: "Site redesign", symbol: "sparkles", state: .live, detail: "Editing Hero.swift"),
        .init(name: "Relay deploy", symbol: "terminal", state: .failed, detail: nil),
        .init(name: "Docs", symbol: "sparkles", state: .live, detail: nil),
    ]

    static func chat(_ state: AgentChatSnapshot.State, activity: String? = nil, done: Int = 2, total: Int = 5, waiting: Int = 0, working: Int = 1) -> AgentChatActivityState {
        let snapshot = AgentChatSnapshot(
            id: "00000000-0000-0000-0000-000000000001", hostID: nil, title: "Peering", symbol: "sparkles", folder: "MacCast",
            state: state, activity: activity, planDone: done, planTotal: total, planStepNumber: done + 1,
            planStep: "Wire the trackpad into the screen view", updatedAt: .now
        )
        return AgentChatActivityState(chat: snapshot, waiting: waiting, working: working, hostKey: nil)
    }

    static func terminal(_ phase: TerminalActivityAttributes.Phase, shells: Int = 1) -> TerminalActivityAttributes.ContentState {
        .init(phase: phase, serverName: "prod-relay", startedAt: phase == .live ? minutesAgo(12) : nil, shellCount: shells)
    }
}

private extension PreviewFixture {
    static var sessionStates: [SessionActivityState] {
        [
            session(.active),
            session(.active, path: .relay, macs: 2, work: work),
            session(.pending, path: nil, minutes: nil),
            session(.reconnecting, path: .direct),
            session(.paused),
            session(.dropped),
        ]
    }

    static var chatStates: [AgentChatActivityState] {
        [
            chat(.needsYou, waiting: 1, working: 2),
            chat(.working, activity: "Editing RemoteScreen+PointerPad.swift"),
            chat(.finished, activity: "Finished the pad", done: 5),
            chat(.failed, done: 3),
        ]
    }

    static var terminalStates: [TerminalActivityAttributes.ContentState] {
        [terminal(.connecting), terminal(.live), terminal(.live, shells: 3)]
    }
}

#Preview("Mac session: Lock Screen", as: .content, using: SessionActivityAttributes()) {
    SessionLiveActivity()
} contentStates: {
    PreviewFixture.sessionStates[0]
    PreviewFixture.sessionStates[1]
    PreviewFixture.sessionStates[2]
    PreviewFixture.sessionStates[3]
    PreviewFixture.sessionStates[4]
    PreviewFixture.sessionStates[5]
}

#Preview("Mac session: Island expanded", as: .dynamicIsland(.expanded), using: SessionActivityAttributes()) {
    SessionLiveActivity()
} contentStates: {
    PreviewFixture.sessionStates[0]
    PreviewFixture.sessionStates[1]
    PreviewFixture.sessionStates[2]
    PreviewFixture.sessionStates[3]
    PreviewFixture.sessionStates[4]
    PreviewFixture.sessionStates[5]
}

#Preview("Mac session: Island compact", as: .dynamicIsland(.compact), using: SessionActivityAttributes()) {
    SessionLiveActivity()
} contentStates: {
    PreviewFixture.sessionStates[0]
    PreviewFixture.sessionStates[1]
    PreviewFixture.sessionStates[2]
    PreviewFixture.sessionStates[3]
    PreviewFixture.sessionStates[4]
    PreviewFixture.sessionStates[5]
}

#Preview("Mac session: Island minimal", as: .dynamicIsland(.minimal), using: SessionActivityAttributes()) {
    SessionLiveActivity()
} contentStates: {
    PreviewFixture.sessionStates[0]
    PreviewFixture.sessionStates[1]
    PreviewFixture.sessionStates[2]
    PreviewFixture.sessionStates[3]
    PreviewFixture.sessionStates[4]
    PreviewFixture.sessionStates[5]
}

#Preview("Agent chat: Lock Screen", as: .content, using: AgentChatActivityAttributes()) {
    AgentChatLiveActivity()
} contentStates: {
    PreviewFixture.chatStates[0]
    PreviewFixture.chatStates[1]
    PreviewFixture.chatStates[2]
    PreviewFixture.chatStates[3]
}

#Preview("Agent chat: Island expanded", as: .dynamicIsland(.expanded), using: AgentChatActivityAttributes()) {
    AgentChatLiveActivity()
} contentStates: {
    PreviewFixture.chatStates[0]
    PreviewFixture.chatStates[1]
    PreviewFixture.chatStates[2]
    PreviewFixture.chatStates[3]
}

#Preview("Agent chat: Island compact", as: .dynamicIsland(.compact), using: AgentChatActivityAttributes()) {
    AgentChatLiveActivity()
} contentStates: {
    PreviewFixture.chatStates[0]
    PreviewFixture.chatStates[1]
    PreviewFixture.chatStates[2]
    PreviewFixture.chatStates[3]
}

#Preview("Agent chat: Island minimal", as: .dynamicIsland(.minimal), using: AgentChatActivityAttributes()) {
    AgentChatLiveActivity()
} contentStates: {
    PreviewFixture.chatStates[0]
    PreviewFixture.chatStates[1]
    PreviewFixture.chatStates[2]
    PreviewFixture.chatStates[3]
}

#Preview("Terminal: Lock Screen", as: .content, using: TerminalActivityAttributes()) {
    TerminalLiveActivity()
} contentStates: {
    PreviewFixture.terminalStates[0]
    PreviewFixture.terminalStates[1]
    PreviewFixture.terminalStates[2]
}

#Preview("Terminal: Island expanded", as: .dynamicIsland(.expanded), using: TerminalActivityAttributes()) {
    TerminalLiveActivity()
} contentStates: {
    PreviewFixture.terminalStates[0]
    PreviewFixture.terminalStates[1]
    PreviewFixture.terminalStates[2]
}

#Preview("Terminal: Island compact", as: .dynamicIsland(.compact), using: TerminalActivityAttributes()) {
    TerminalLiveActivity()
} contentStates: {
    PreviewFixture.terminalStates[0]
    PreviewFixture.terminalStates[1]
    PreviewFixture.terminalStates[2]
}
