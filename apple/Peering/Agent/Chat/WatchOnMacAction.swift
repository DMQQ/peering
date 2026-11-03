import SwiftUI

/// Set by the session screen that hosts the chat; nil where nothing can show the Mac's picture.
private struct WatchOnMacKey: EnvironmentKey {
    static let defaultValue: (@MainActor (UUID) -> Void)? = nil
}

extension EnvironmentValues {
    var watchOnMac: (@MainActor (UUID) -> Void)? {
        get { self[WatchOnMacKey.self] }
        set { self[WatchOnMacKey.self] = newValue }
    }
}
