import RemoteCore
import SwiftUI

/// The keys a trackpad cannot stand in for. Codes are macOS hardware keycodes.
enum RemoteDockKey: CaseIterable, Identifiable {
    case escape, tab, left, down, up, right, returnKey, delete

    var id: Self { self }

    var keyCode: UInt16 {
        switch self {
        case .escape: 53
        case .tab: 48
        case .left: 123
        case .down: 125
        case .up: 126
        case .right: 124
        case .returnKey: 36
        case .delete: 51
        }
    }

    var symbol: String {
        switch self {
        case .escape: "escape"
        case .tab: "arrow.right.to.line"
        case .left: "arrow.left"
        case .down: "arrow.down"
        case .up: "arrow.up"
        case .right: "arrow.right"
        case .returnKey: "return"
        case .delete: "delete.left"
        }
    }

    var label: String {
        switch self {
        case .escape: String(localized: "Escape")
        case .tab: String(localized: "Tab")
        case .left: String(localized: "Left arrow")
        case .down: String(localized: "Down arrow")
        case .up: String(localized: "Up arrow")
        case .right: String(localized: "Right arrow")
        case .returnKey: String(localized: "Return")
        case .delete: String(localized: "Delete")
        }
    }

    /// Short enough to sit under the icon in a rail button.
    var shortName: String {
        switch self {
        case .escape: "Esc"
        case .tab: String(localized: "Tab")
        case .left, .down, .up, .right: ""
        case .returnKey: String(localized: "Return")
        case .delete: String(localized: "Delete")
        }
    }
}
