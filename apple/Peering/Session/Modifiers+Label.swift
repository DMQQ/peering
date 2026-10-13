import Foundation
import MacCastKit
import Observation
import RemoteCore
import SwiftUI
import UIKit
import WidgetKit
import os

extension Modifiers {
    /// Symbols, not words: read next to the same glyphs the buttons use.
    var label: String {
        var names: [String] = []
        if contains(.command) { names.append("⌘") }
        if contains(.shift) { names.append("⇧") }
        if contains(.option) { names.append("⌥") }
        if contains(.control) { names.append("⌃") }
        return names.isEmpty ? String(localized: "a modifier") : names.joined()
    }
}
