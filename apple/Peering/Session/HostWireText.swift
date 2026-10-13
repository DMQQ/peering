import Foundation
import MacCastKit
import RemoteCore

/// The Mac and the networking libraries word their errors in English. The phone shows the ones it
/// knows in its own language and passes every other sentence through unchanged, so a Mac newer than
/// this build never has its text swallowed.
///
/// Matching reads the English, so call this at the point of display and keep the original for any
/// code that branches on the sentence (see `HostPickerView.failurePresentation`).
enum HostWireText {
    static func localized(_ text: String) -> String {
        sentence(text) ?? firstLineWithTail(text) ?? text
    }

    private static func sentence(_ text: String) -> String? {
        connection(text) ?? handshake(text) ?? files(text) ?? terminal(text) ?? agentLine(text) ?? ssh(text) ?? patterned(text)
    }

    /// A sentence followed by what a tool printed after it: the sentence is the Mac's, the rest is not.
    private static func firstLineWithTail(_ text: String) -> String? {
        guard let newline = text.firstIndex(of: "\n"), let head = sentence(String(text[..<newline])) else { return nil }
        return head + text[newline...]
    }

    static func localized(_ text: String?) -> String? {
        text.map(localized)
    }

    private static func patterned(_ text: String) -> String? {
        patternedConnection(text) ?? patternedHost(text) ?? patternedNote(text)
    }

    private static func patternedConnection(_ text: String) -> String? {
        if let found = SentenceTemplate.arguments(
            in: text,
            template: "Something at this address is not the Mac you paired with (%@). Its key does not match the key this iPhone pinned for it. If the Mac was reset, forget it here and pair again."
        ) {
            return String(localized: "Something at this address is not the Mac you paired with (\(found[0])). Its key does not match the key this iPhone pinned for it. If the Mac was reset, forget it here and pair again.")
        }
        if let found = SentenceTemplate.arguments(
            in: text,
            template: "This iPhone has no pairing on file for that Mac (%@). The Mac still trusts this iPhone, so it will not ask to pair again: on the Mac, open Devices and forget this iPhone, then pair again."
        ) {
            return String(localized: "This iPhone has no pairing on file for that Mac (\(found[0])). The Mac still trusts this iPhone, so it will not ask to pair again: on the Mac, open Devices and forget this iPhone, then pair again.")
        }
        if let found = SentenceTemplate.arguments(
            in: text,
            template: "A different Mac answered: %@, not %@. Check that the code you scanned or typed came from the Mac you meant."
        ) {
            return String(localized: "A different Mac answered: \(found[0]), not \(found[1]). Check that the code you scanned or typed came from the Mac you meant.")
        }
        return nil
    }

    private static func patternedHost(_ text: String) -> String? {
        if let found = SentenceTemplate.arguments(in: text, template: "There is no folder at %@ on this Mac.") {
            return String(localized: "There is no folder at \(found[0]) on this Mac.")
        }
        if let found = SentenceTemplate.arguments(in: text, template: "Could not start the login shell: %@") {
            return String(localized: "Could not start the login shell: \(found[0])")
        }
        if let found = SentenceTemplate.arguments(in: text, template: "That file is too large to send to this Mac (the limit is %@).") {
            return String(localized: "That file is too large to send to this Mac (the limit is \(found[0])).")
        }
        if let found = SentenceTemplate.arguments(in: text, template: "%@ is not installed on this Mac, or its command is not on the login shell's PATH.") {
            return String(localized: "\(found[0]) is not installed on this Mac, or its command is not on the login shell's PATH.")
        }
        if let found = SentenceTemplate.arguments(in: text, template: "%@ could not be started.") {
            return String(localized: "\(found[0]) could not be started.")
        }
        if let found = SentenceTemplate.arguments(in: text, template: "Terminal \u{201C}%@\u{201D} is waiting for a password.") {
            return String(localized: "Terminal \u{201C}\(found[0])\u{201D} is waiting for a password.")
        }
        if let found = SentenceTemplate.arguments(in: text, template: "Terminal \u{201C}%@\u{201D} is waiting for confirmation.") {
            return String(localized: "Terminal \u{201C}\(found[0])\u{201D} is waiting for confirmation.")
        }
        return patternedFinished(text) ?? patternedNumber(text)
    }

    private static func patternedFinished(_ text: String) -> String? {
        guard let finished = FinishedSentence(parsing: text) else { return nil }
        let duration = finished.seconds.map { TerminalCommandFinishDetector.spokenDuration($0) } ?? finished.duration
        let named = switch finished.subject {
        case .command(let command): "\u{201C}\(command)\u{201D}"
        case .terminal(let name): String(localized: "Terminal \u{201C}\(name)\u{201D}")
        }
        return String(localized: "\(named) finished after \(duration).")
    }

    private static func patternedNumber(_ text: String) -> String? {
        if let number = number(in: text, template: "That file is larger than this app moves (%@ MB).") {
            return String(localized: "That file is larger than this app moves (\(number) MB).")
        }
        if let number = number(in: text, template: "That folder zips to more than this app moves (%@ MB).") {
            return String(localized: "That folder zips to more than this app moves (\(number) MB).")
        }
        if let number = number(in: text, template: "%@ of this Mac's displays are still visible: Privacy Mode could not cover them.") {
            return String(localized: "\(number) of this Mac's displays are still visible: Privacy Mode could not cover them.")
        }
        return nil
    }

    private static func number(in text: String, template: String) -> Int? {
        SentenceTemplate.arguments(in: text, template: template)?.first.flatMap { Int($0) }
    }
}
