import PeeringKit

extension Analytics {
    /// `source` is `picker` when the person chose and `remembered` when the Mac opened in the mode last chosen for it.
    static func sessionModeChosen(_ mode: SessionMode, source: String) {
        send("session_mode_chosen", ["mode": mode.rawValue, "source": source])
    }

    static func sessionModeChanged(from: SessionMode, to: SessionMode) {
        send("session_mode_changed", ["from": from.rawValue, "to": to.rawValue])
    }
}
