import Foundation

extension HostWireText {
    /// File browsing, transfers and the notices the Mac raises about its screen.
    static func files(_ text: String) -> String? {
        switch text {
        case "That is not a path this Mac can open.": String(localized: "That is not a path this Mac can open.")
        case "That is not a path this Mac can write to.": String(localized: "That is not a path this Mac can write to.")
        case "That is not a path this Mac can change.": String(localized: "That is not a path this Mac can change.")
        case "That is not a name a file can have.": String(localized: "That is not a name a file can have.")
        case "That folder is no longer there.": String(localized: "That folder is no longer there.")
        case "That is too much of this Mac to delete.": String(localized: "That is too much of this Mac to delete.")
        case "That transfer was sent in pieces this Mac cannot accept.":
            String(localized: "That transfer was sent in pieces this Mac cannot accept.")
        case "That file is no longer being written. Choose it again.": String(localized: "That file is no longer being written. Choose it again.")
        case "That transfer sent more than it said it would.": String(localized: "That transfer sent more than it said it would.")
        case "That transfer stopped before the whole file arrived.": String(localized: "That transfer stopped before the whole file arrived.")
        case "That transfer stopped sending, so this Mac dropped it.": String(localized: "That transfer stopped sending, so this Mac dropped it.")
        case "This Mac's disk is not keeping up, so that transfer was stopped.":
            String(localized: "This Mac's disk is not keeping up, so that transfer was stopped.")
        case "This Mac could not make room for the zip.": String(localized: "This Mac could not make room for the zip.")
        case "This Mac could not zip that folder.": String(localized: "This Mac could not zip that folder.")
        case "There is not enough free space on this Mac to zip that folder.":
            String(localized: "There is not enough free space on this Mac to zip that folder.")
        case "This Mac did not answer in time. The folder may be on a drive that is not responding.":
            String(localized: "This Mac did not answer in time. The folder may be on a drive that is not responding.")
        case "This Mac is busy with other file requests. Try again in a moment.":
            String(localized: "This Mac is busy with other file requests. Try again in a moment.")
        case "That is not a file, so there is nothing to show here.": String(localized: "That is not a file, so there is nothing to show here.")
        case "That file is not text, a picture, a video or a PDF, so there is nothing to show here.":
            String(localized: "That file is not text, a picture, a video or a PDF, so there is nothing to show here.")
        case "That file is not text or a picture, so there is nothing to show here.":
            String(localized: "That file is not text or a picture, so there is nothing to show here.")
        case "Something with that name is already there.": String(localized: "Something with that name is already there.")
        case "That is no longer there.": String(localized: "That is no longer there.")
        case "That disk can only be read from, so nothing can be changed on it.":
            String(localized: "That disk can only be read from, so nothing can be changed on it.")
        case "That name is too long for this Mac.": String(localized: "That name is too long for this Mac.")
        case "Part of that path is not a folder.": String(localized: "Part of that path is not a folder.")
        case "Peering is not allowed to read this. Allow Peering in Files and Folders under Privacy and Security on the Mac.":
            String(localized: "Peering is not allowed to read this. Allow Peering in Files and Folders under Privacy and Security on the Mac.")
        default: notice(text)
        }
    }

    private static func notice(_ text: String) -> String? {
        switch text {
        case "This Mac is locked.": String(localized: "This Mac is locked.")
        case "That display is no longer connected. Choose another from Sources.":
            String(localized: "That display is no longer connected. Choose another from Sources.")
        case "This Mac's screen is asleep.": String(localized: "This Mac's screen is asleep.")
        case "Privacy Mode could not darken this Mac's displays.": String(localized: "Privacy Mode could not darken this Mac's displays.")
        case "One of this Mac's displays is still visible: Privacy Mode could not cover it.":
            String(localized: "One of this Mac's displays is still visible: Privacy Mode could not cover it.")
        default: nil
        }
    }
}
