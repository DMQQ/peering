import Foundation

/// How many agent chats may be open at once. A chat that has ended or failed does not count.
public enum AgentChatLimit {
    public static let freeActiveChats = 3

    public static func allowsAnother(openChats: Int, access: PlanAccess) -> Bool {
        access.includes(.moreAgents) || openChats < freeActiveChats
    }
}
