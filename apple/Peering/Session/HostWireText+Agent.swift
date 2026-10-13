import Foundation
import PeeringKit

extension HostWireText {
    /// Transcript lines, git outcomes and folder-access notes the Mac writes for an agent chat. The
    /// transcript keeps the English, because `AgentPause.isPaused` reads it, so this runs at display.
    static func agentLine(_ text: String) -> String? {
        switch text {
        case AgentPause.notice:
            String(localized: "Stopped and moved to history. Send a message to pick this chat up where it left off.")
        case AgentExpiry.message:
            String(localized: "Claude Code can no longer reopen this conversation. You can read it here.")
        case AgentGitLocator.missingMessage:
            String(localized: "git is not installed on this Mac. Install the Xcode Command Line Tools (run xcode-select --install in Terminal) to review changes.")
        case "Your Mac is probably asking whether Peering may open this folder. That is a normal macOS question, asked once per folder. Choose Allow on the Mac and the list appears here.":
            String(localized: "Your Mac is probably asking whether Peering may open this folder. That is a normal macOS question, asked once per folder. Choose Allow on the Mac and the list appears here.")
        case "Waiting for your Mac. macOS asks once per folder before an app may open it: choose Allow on the Mac. Peering and the agent only read what you ask them to.":
            String(localized: "Waiting for your Mac. macOS asks once per folder before an app may open it: choose Allow on the Mac. Peering and the agent only read what you ask them to.")
        case "Peering could not read this folder. If macOS blocked it, you can allow it in System Settings, Privacy & Security, Files and Folders.":
            String(localized: "Peering could not read this folder. If macOS blocked it, you can allow it in System Settings, Privacy & Security, Files and Folders.")
        case "A line from the agent was too long to read and was skipped.":
            String(localized: "A line from the agent was too long to read and was skipped.")
        case "That model was not accepted.": String(localized: "That model was not accepted.")
        case "That mode was not accepted.": String(localized: "That mode was not accepted.")
        case "Continued from a Claude Code session started on this Mac.":
            String(localized: "Continued from a Claude Code session started on this Mac.")
        case "Claude Code started and stopped before saying anything. Update it, or use the terminal instead.":
            String(localized: "Claude Code started and stopped before saying anything. Update it, or use the terminal instead.")
        default: agentExit(text) ?? git(text)
        }
    }

    private static func agentExit(_ text: String) -> String? {
        if let found = SentenceTemplate.arguments(in: text, template: "%@ exited with status %@ before finishing the turn.") {
            return String(localized: "\(found[0]) exited with status \(found[1]) before finishing the turn.")
        }
        if let found = SentenceTemplate.arguments(in: text, template: "Claude Code exited with status %@.") {
            return String(localized: "Claude Code exited with status \(found[0]).")
        }
        return nil
    }

    private static func git(_ text: String) -> String? {
        switch text {
        case "git stopped without saying why. It may have run out of time.":
            String(localized: "git stopped without saying why. It may have run out of time.")
        case "Committed.": String(localized: "Committed.")
        case "Pushed.": String(localized: "Pushed.")
        case "This folder's branch could not be read.": String(localized: "This folder's branch could not be read.")
        case "The Mac has no saved credential for this remote, and git cannot ask for one from here.":
            String(localized: "The Mac has no saved credential for this remote, and git cannot ask for one from here.")
        case "Choose at least one file to commit.": String(localized: "Choose at least one file to commit.")
        case "That is too many files for one commit from the phone.":
            String(localized: "That is too many files for one commit from the phone.")
        case "A commit needs a message.": String(localized: "A commit needs a message.")
        case "That commit message is too long.": String(localized: "That commit message is too long.")
        case "This folder is not on a branch (detached HEAD), so there is nothing to push.":
            String(localized: "This folder is not on a branch (detached HEAD), so there is nothing to push.")
        case "This branch has no upstream. Set one on the Mac, then push from here.":
            String(localized: "This branch has no upstream. Set one on the Mac, then push from here.")
        case "This branch's name is not one the phone will push.":
            String(localized: "This branch's name is not one the phone will push.")
        case "This branch's remote is not one the phone will push to.":
            String(localized: "This branch's remote is not one the phone will push to.")
        default:
            SentenceTemplate.arguments(in: text, template: "%@ is not a file inside this folder.")
                .map { String(localized: "\($0[0]) is not a file inside this folder.") }
        }
    }
}
