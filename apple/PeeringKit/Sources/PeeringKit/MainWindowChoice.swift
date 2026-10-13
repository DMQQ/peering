import Foundation

/// Which of the app's windows is the main one, given only their identifiers, so the choice can be tested without AppKit.
public enum MainWindowChoice {
    /// SwiftUI names a `WindowGroup(id:)` window `<id>-AppWindow-<n>`. A window that can become main but has another name (a leftover panel or sheet host) is used only when nothing is named for the group.
    public static func index(of groupID: String, identifiers: [String?], canBecomeMain: [Bool]) -> Int? {
        let named = identifiers.indices.first { index in
            guard let identifier = identifiers[index] else { return false }
            return identifier == groupID || identifier.hasPrefix(groupID + "-")
        }
        return named ?? canBecomeMain.firstIndex(of: true)
    }
}
