import Foundation

/// Which of the chat's three bodies is showing: its history on the way, nothing said yet, or the conversation.
public enum AgentChatPhase: Equatable {
    case loading
    case empty
    case conversation

    /// A chat whose history never arrived (an older Mac) gives up loading and reads as empty.
    public static func of(transcriptIsEmpty: Bool, isLoaded: Bool, gaveUpLoading: Bool) -> AgentChatPhase {
        guard transcriptIsEmpty else { return .conversation }
        return !isLoaded && !gaveUpLoading ? .loading : .empty
    }
}
