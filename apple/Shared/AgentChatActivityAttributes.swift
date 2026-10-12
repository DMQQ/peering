import ActivityKit
import Foundation

nonisolated struct AgentChatActivityAttributes: ActivityAttributes {
    typealias ContentState = AgentChatActivityState

    /// Nothing varies per card; a push-to-start needs a non-empty attributes object, and this is what the Mac puts in it.
    var origin: String?
}
