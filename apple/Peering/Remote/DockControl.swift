import RemoteCore
import SwiftUI
import UIKit

enum DockControl: String, CaseIterable, Identifiable {
    case sources, keys, clipboard, shortcuts, tab
    case left, up, down, right, delete
    case escape, mode, settings

    var id: String { rawValue }

    static let navigation: [DockControl] = [.up, .down, .left, .right, .delete]
}
