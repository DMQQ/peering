import Foundation

/// Temporary, DEBUG-only stdout trace used by `devicectl --console` on a wireless iPhone.
nonisolated func flickerTrace(_ message: String) {
    #if DEBUG
    print("[DEBUG-flicker-923] \(Date().timeIntervalSince1970) \(message)")
    fflush(stdout)
    #endif
}
