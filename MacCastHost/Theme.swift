import SwiftUI

/// The host's palette, matching the client's.
///
/// Semantic rather than literal, which is the one place the two deliberately differ: the phone
/// is dark by fiat, and this is a Mac app living in a window that may be in either appearance.
/// `primary` and `secondary` *are* the ink and the muted ink of whichever one is current, so a
/// state means the same thing in both and nothing has to be picked per mode.
///
/// Two copies of eight constants, because sharing them would mean moving this into `RemoteCore`
/// — the wire protocol — and a UI dependency there would outlive any benefit from saving them.
enum HostPalette {
    /// The ink: selection, a live session, anything that is on.
    static let ink = Color.primary
    /// Muted ink: a state that is neither good nor bad, and the resting tone for labels.
    static let muted = Color.secondary
    /// The quietest tone that still reads: idle, absent, switched off.
    ///
    /// `Color.secondary` dimmed rather than a `.tertiary` style: there is no tertiary *colour*,
    /// only a hierarchical style, and this has to be usable anywhere a `Color` is expected.
    static let faint = Color.secondary.opacity(0.55)
    /// A panel's own fill.
    static let surface = Color(nsColor: .controlBackgroundColor)
    /// A fill that stands slightly off the panel behind it.
    static let raised = Color.primary.opacity(0.07)
}
