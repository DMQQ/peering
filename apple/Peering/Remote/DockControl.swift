import RemoteCore
import SwiftUI
import UIKit

enum DockControl: String, CaseIterable, Identifiable {
    case sources, keys, trackpad, clipboard, shortcuts, tab
    case left, up, down, right, delete
    case escape, mode, settings

    var id: String { rawValue }

    static let navigation: [DockControl] = [.up, .down, .left, .right, .delete]

    /// What the portrait dock shows. The arrows, Delete, Esc and Tab are in the shortcuts panel, so a second copy here only pushes the controls that live nowhere else onto another page.
    static let portrait: [DockControl] = allCases.filter { !navigation.contains($0) && $0 != .escape && $0 != .tab }
}
