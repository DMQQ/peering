import Foundation
import MacCastKit
import Observation
import RemoteCore
import SwiftUI
import UIKit
import WidgetKit
import os

struct Macro: Identifiable, Hashable, Codable {
    let id: String
    let title: String
    let keyCode: UInt16
    let modifiers: Modifiers

    static let defaults: [Macro] = [
        // macOS virtual keycodes, the values `CGEvent` takes, not USB HID usages or characters.
        Macro(id: "copy",      title: "⌘C",     keyCode: 8,  modifiers: .command),
        Macro(id: "paste",     title: "⌘V",     keyCode: 9,  modifiers: .command),
        Macro(id: "cut",       title: "⌘X",     keyCode: 7,  modifiers: .command),
        Macro(id: "undo",      title: "⌘Z",     keyCode: 6,  modifiers: .command),
        Macro(id: "save",      title: "⌘S",     keyCode: 1,  modifiers: .command),
        Macro(id: "close",     title: "⌘W",     keyCode: 13, modifiers: .command),
        Macro(id: "appswitch", title: "⌘⇥",     keyCode: 48, modifiers: .command),
        Macro(id: "spotlight", title: "⌘Space", keyCode: 49, modifiers: .command),
        Macro(id: "escape",    title: "esc",    keyCode: 53, modifiers: []),
        Macro(id: "return",    title: "⏎",      keyCode: 36, modifiers: []),
        Macro(id: "ctrl-c",    title: "⌃C",     keyCode: 8,  modifiers: .control),
        Macro(id: "ctrl-z",    title: "⌃Z",     keyCode: 6,  modifiers: .control),
        Macro(id: "ctrl-d",    title: "⌃D",     keyCode: 2,  modifiers: .control),
        Macro(id: "ctrl-l",    title: "⌃L",     keyCode: 37, modifiers: .control),
        Macro(id: "ctrl-a",    title: "⌃A",     keyCode: 0,  modifiers: .control),
        Macro(id: "ctrl-e",    title: "⌃E",     keyCode: 14, modifiers: .control),
        Macro(id: "ctrl-r",    title: "⌃R",     keyCode: 15, modifiers: .control),
    ]
}
