import Foundation

/// Decides what the What's New sheet does at launch. The release's text lives in the app, where it is localized; only its id is compared here.
public enum WhatsNewPolicy {
    public enum Decision: Equatable, Sendable {
        case show
        /// Nothing to present, but the release must be recorded so it is not shown later as news.
        case recordWithoutShowing
        case nothing
    }

    /// A first-time user has not met the previous version, so the sheet would describe changes to something they never used: the release is recorded and the tour does the introducing.
    public static func decide(currentRelease: String?, lastSeenRelease: String?, hasSeenWelcome: Bool) -> Decision {
        guard let currentRelease, currentRelease != lastSeenRelease else { return .nothing }
        return hasSeenWelcome ? .show : .recordWithoutShowing
    }
}
