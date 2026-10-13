import Foundation
import WatchLink

/// Sample questions for App Store screenshots: `-PeeringDemo` fills the list, `-PeeringDemoDetail N` opens the Nth.
enum DemoApprovals {
    #if DEBUG
    static var isOn: Bool { CommandLine.arguments.contains("-PeeringDemo") }

    static var approvals: [WatchApproval] {
        let session = UUID()
        let now = Date()
        return [
            WatchApproval(approvalID: "d1", sessionID: session, hostID: "mac", chatTitle: "Fix login bug", hostName: "Studio Mac", body: "npm test -- --watch=false", kind: .allowDeny, postedAt: now),
            WatchApproval(approvalID: "d2", sessionID: session, hostID: "mac", chatTitle: "Refactor billing", hostName: "Studio Mac", body: "Which database should the migration target?", kind: .options, answers: ["Postgres", "SQLite", "Keep both"], postedAt: now.addingTimeInterval(-60)),
            WatchApproval(approvalID: "d3", sessionID: session, hostID: "mac", chatTitle: "Release notes", hostName: "Studio Mac", body: "rm -rf build && swift build", kind: .allowDeny, postedAt: now.addingTimeInterval(-300)),
        ]
    }

    static var initialPath: [WatchApproval] {
        guard let flag = CommandLine.arguments.firstIndex(of: "-PeeringDemoDetail"),
              CommandLine.arguments.indices.contains(flag + 1),
              let index = Int(CommandLine.arguments[flag + 1]), approvals.indices.contains(index)
        else { return [] }
        return [approvals[index]]
    }
    #else
    static let isOn = false
    static let approvals: [WatchApproval] = []
    static let initialPath: [WatchApproval] = []
    #endif
}
