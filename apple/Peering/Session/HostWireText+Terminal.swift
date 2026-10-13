import Foundation

extension HostWireText {
    /// Terminal and agent chat refusals from the Mac.
    static func terminal(_ text: String) -> String? {
        switch text {
        case "Could not create a terminal.": String(localized: "Could not create a terminal.")
        case "Terminal session limit reached.": String(localized: "Terminal session limit reached.")
        case "Terminal input was too large.": String(localized: "Terminal input was too large.")
        case "That terminal is no longer running.": String(localized: "That terminal is no longer running.")
        case "Could not write to the terminal.": String(localized: "Could not write to the terminal.")
        case "The authenticated device has no identity.": String(localized: "The authenticated device has no identity.")
        default: agent(text)
        }
    }

    private static func agent(_ text: String) -> String? {
        switch text {
        case "That prompt is too long to send.": String(localized: "That prompt is too long to send.")
        case "That chat cannot be continued. Start a new one.": String(localized: "That chat cannot be continued. Start a new one.")
        case "This agent cannot run in that mode.": String(localized: "This agent cannot run in that mode.")
        case "That chat is no longer here.": String(localized: "That chat is no longer here.")
        case "This app cannot chat with that agent.": String(localized: "This app cannot chat with that agent.")
        case "That is not a folder this Mac can open.": String(localized: "That is not a folder this Mac can open.")
        case "Chat session limit reached.": String(localized: "Chat session limit reached.")
        case "That agent could not be started.": String(localized: "That agent could not be started.")
        case "Claude Code is not installed on this Mac, or its command is not on the login shell's PATH.":
            String(localized: "Claude Code is not installed on this Mac, or its command is not on the login shell's PATH.")
        case "Stop the turn before moving this chat to history.": String(localized: "Stop the turn before moving this chat to history.")
        case "Only Claude Code conversations can be continued from here yet.":
            String(localized: "Only Claude Code conversations can be continued from here yet.")
        case "That conversation is no longer on this Mac.": String(localized: "That conversation is no longer on this Mac.")
        case "This folder is not in a git repository, so only the agent's own edits are listed.":
            String(localized: "This folder is not in a git repository, so only the agent's own edits are listed.")
        case "This folder is not in a git repository.": String(localized: "This folder is not in a git repository.")
        default: nil
        }
    }
}
