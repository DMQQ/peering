import Foundation
import MacCastKit
import Observation
import RemoteCore
import SwiftUI
import UIKit
import WidgetKit
import os

/// Which keyboard the user is driving the Mac with.
/// Not a preference: the two are different protocols. `unicode` sends `textInput` (emoji and CJK arrive intact, but no keycode is pressed so ⌘S never fires); `keycode` presses real virtual keycodes, so shortcuts work but a character with no keycode on the Mac's layout cannot be typed.
enum KeyboardMode: String, CaseIterable, Identifiable {
    case unicode
    case keycode

    var id: String { rawValue }

    var label: String {
        switch self {
        case .unicode: return String(localized: "Unicode")
        case .keycode: return String(localized: "Keycode")
        }
    }

    var explanation: String {
        switch self {
        case .unicode:
            return String(localized: "Sends text. Emoji and non-Latin scripts work; Mac shortcuts like ⌘S do not.")
        case .keycode:
            return String(localized: "Sends real key presses with modifiers. Shortcuts work; characters outside the Mac's layout cannot be typed.")
        }
    }
}
