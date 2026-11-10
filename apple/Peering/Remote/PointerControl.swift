import Foundation

/// What portrait shows on the screen for the pointer. The trackpad panel is always on the dock; this decides whether the joystick sits beside Back and Enter as well. Landscape has no room for a pad and always shows the joystick.
enum PointerControl: String, CaseIterable, Identifiable {
    case trackpad
    case joystick

    var id: String { rawValue }

    var label: String {
        switch self {
        case .trackpad: String(localized: "Trackpad only")
        case .joystick: String(localized: "Joystick")
        }
    }
}
