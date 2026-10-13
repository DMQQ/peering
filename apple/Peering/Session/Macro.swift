import Foundation
import PeeringKit
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
        Macro(id: "select-all", title: "⌘A",    keyCode: 0,  modifiers: .command),
        Macro(id: "undo",      title: "⌘Z",     keyCode: 6,  modifiers: .command),
        Macro(id: "redo",      title: "⇧⌘Z",    keyCode: 6,  modifiers: [.command, .shift]),
        Macro(id: "save",      title: "⌘S",     keyCode: 1,  modifiers: .command),
        Macro(id: "find",      title: "⌘F",     keyCode: 3,  modifiers: .command),
        Macro(id: "new",       title: "⌘N",     keyCode: 45, modifiers: .command),
        Macro(id: "open",      title: "⌘O",     keyCode: 31, modifiers: .command),
        Macro(id: "print",     title: "⌘P",     keyCode: 35, modifiers: .command),
        Macro(id: "new-tab",   title: "⌘T",     keyCode: 17, modifiers: .command),
        Macro(id: "reopen-tab", title: "⇧⌘T",   keyCode: 17, modifiers: [.command, .shift]),
        Macro(id: "reload",    title: "⌘R",     keyCode: 15, modifiers: .command),
        Macro(id: "address",   title: "⌘L",     keyCode: 37, modifiers: .command),
        Macro(id: "back",      title: "⌘[",     keyCode: 33, modifiers: .command),
        Macro(id: "forward",   title: "⌘]",     keyCode: 30, modifiers: .command),
        Macro(id: "zoom-in",   title: "⌘+",     keyCode: 24, modifiers: .command),
        Macro(id: "zoom-out",  title: "⌘-",     keyCode: 27, modifiers: .command),
        Macro(id: "zoom-reset", title: "⌘0",    keyCode: 29, modifiers: .command),
        Macro(id: "close",     title: "⌘W",     keyCode: 13, modifiers: .command),
        Macro(id: "quit",      title: "⌘Q",     keyCode: 12, modifiers: .command),
        Macro(id: "hide",      title: "⌘H",     keyCode: 4,  modifiers: .command),
        Macro(id: "minimise",  title: "⌘M",     keyCode: 46, modifiers: .command),
        Macro(id: "next-window", title: "⌘`",   keyCode: 50, modifiers: .command),
        Macro(id: "preferences", title: "⌘,",   keyCode: 43, modifiers: .command),
        Macro(id: "appswitch", title: "⌘⇥",     keyCode: 48, modifiers: .command),
        Macro(id: "spotlight", title: "⌘Space", keyCode: 49, modifiers: .command),
        Macro(id: "screenshot", title: "⇧⌘4",   keyCode: 21, modifiers: [.command, .shift]),
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
