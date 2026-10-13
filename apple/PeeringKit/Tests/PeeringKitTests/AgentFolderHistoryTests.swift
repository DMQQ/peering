import Foundation
import Testing

@testable import PeeringKit

struct AgentFolderHistoryTests {
    private func defaults() -> UserDefaults {
        let name = "AgentFolderHistoryTests." + UUID().uuidString
        let suite = UserDefaults(suiteName: name)!
        suite.removePersistentDomain(forName: name)
        return suite
    }

    @Test func recordsNewestFirst() {
        let store = defaults()
        AgentFolderHistory.record(directory: "/a", agentID: "claude", macName: "M", at: Date(timeIntervalSince1970: 1), in: store)
        AgentFolderHistory.record(directory: "/b", agentID: "claude", macName: "M", at: Date(timeIntervalSince1970: 2), in: store)
        #expect(AgentFolderHistory.load(from: store).map(\.path) == ["/b", "/a"])
    }

    @Test func clearingOneKindLeavesTheOthers() {
        let store = defaults()
        AgentFolderHistory.record(directory: "/a", agentID: "claude", macName: "M", in: store)
        AgentFolderHistory.record(directory: "/b", agentID: AgentFolderHistory.terminalAgentID, macName: "M", in: store)
        AgentFolderHistory.clear(agentID: AgentFolderHistory.terminalAgentID, in: store)
        #expect(AgentFolderHistory.load(from: store).map(\.path) == ["/a"])
    }

    @Test func theSameFolderForTheSameAgentMovesUpInsteadOfRepeating() {
        let store = defaults()
        AgentFolderHistory.record(directory: "/a", agentID: "claude", macName: "M", at: Date(timeIntervalSince1970: 1), in: store)
        AgentFolderHistory.record(directory: "/b", agentID: "claude", macName: "M", at: Date(timeIntervalSince1970: 2), in: store)
        AgentFolderHistory.record(directory: "/a", agentID: "claude", macName: "M", at: Date(timeIntervalSince1970: 3), in: store)
        #expect(AgentFolderHistory.load(from: store).map(\.path) == ["/a", "/b"])
    }

    @Test func theSameFolderForAnotherAgentIsItsOwnRow() {
        let store = defaults()
        AgentFolderHistory.record(directory: "/a", agentID: "claude", macName: "M", at: Date(timeIntervalSince1970: 1), in: store)
        AgentFolderHistory.record(directory: "/a", agentID: "codex", macName: "M", at: Date(timeIntervalSince1970: 2), in: store)
        #expect(AgentFolderHistory.load(from: store).count == 2)
    }

    @Test func noChoiceRecordsNothing() {
        let store = defaults()
        AgentFolderHistory.record(directory: nil, agentID: "claude", macName: "M", in: store)
        #expect(AgentFolderHistory.load(from: store).isEmpty)
    }

    @Test func keepsTheTwentyFiveNewest() {
        let store = defaults()
        for number in 0..<30 {
            AgentFolderHistory.record(
                directory: "/f\(number)", agentID: "claude", macName: nil,
                at: Date(timeIntervalSince1970: TimeInterval(number)), in: store
            )
        }
        let kept = AgentFolderHistory.load(from: store)
        #expect(kept.count == 25)
        #expect(kept.first?.path == "/f29")
        #expect(kept.last?.path == "/f5")
    }
}

struct AgentFolderPathTests {
    @Test func parentOfARootChildIsTheRoot() {
        #expect(AgentFolderPath.parent(of: "/Users") == "/")
        #expect(AgentFolderPath.parent(of: "/Users/me/app") == "/Users/me")
    }

    @Test func rootAndUnknownHaveNoParent() {
        #expect(AgentFolderPath.parent(of: "/") == nil)
        #expect(AgentFolderPath.parent(of: nil) == nil)
    }

    @Test func nameIsTheLastComponentAndTheRootIsASlash() {
        #expect(AgentFolderPath.name(of: "/Users/me/app") == "app")
        #expect(AgentFolderPath.name(of: "/") == "/")
    }}

struct AgentTurnFormatTests {
    @Test func underAMinuteShowsTenths() {
        #expect(AgentTurnFormat.duration(4.25) == "4.2s" || AgentTurnFormat.duration(4.25) == "4.3s")
        #expect(AgentTurnFormat.duration(0) == "0.0s")
    }

    @Test func aMinuteOrMoreShowsMinutesAndSeconds() {
        #expect(AgentTurnFormat.duration(60) == "1m 0s")
        #expect(AgentTurnFormat.duration(125.9) == "2m 5s")
    }
}
