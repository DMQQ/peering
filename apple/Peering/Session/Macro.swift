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

    static func defaults(for platform: HostPlatform) -> [Macro] {
        switch platform {
        case .mac: macDefaults
        case .windows: windowsDefaults
        }
    }

    private static let macDefaults: [Macro] = [
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
    /// The wire carries macOS keycodes for every host. A Windows host reads Command as Ctrl and Option as Alt, and keycode 256 as the Windows key.
    private static let windowsDefaults: [Macro] = [
        Macro(id: "copy",       title: "Ctrl+C",       keyCode: 8,   modifiers: .command),
        Macro(id: "paste",      title: "Ctrl+V",       keyCode: 9,   modifiers: .command),
        Macro(id: "cut",        title: "Ctrl+X",       keyCode: 7,   modifiers: .command),
        Macro(id: "select-all", title: "Ctrl+A",       keyCode: 0,   modifiers: .command),
        Macro(id: "undo",       title: "Ctrl+Z",       keyCode: 6,   modifiers: .command),
        Macro(id: "redo",       title: "Ctrl+Y",       keyCode: 16,  modifiers: .command),
        Macro(id: "save",       title: "Ctrl+S",       keyCode: 1,   modifiers: .command),
        Macro(id: "find",       title: "Ctrl+F",       keyCode: 3,   modifiers: .command),
        Macro(id: "new",        title: "Ctrl+N",       keyCode: 45,  modifiers: .command),
        Macro(id: "open",       title: "Ctrl+O",       keyCode: 31,  modifiers: .command),
        Macro(id: "print",      title: "Ctrl+P",       keyCode: 35,  modifiers: .command),
        Macro(id: "new-tab",    title: "Ctrl+T",       keyCode: 17,  modifiers: .command),
        Macro(id: "reopen-tab", title: "Ctrl+Shift+T", keyCode: 17,  modifiers: [.command, .shift]),
        Macro(id: "reload",     title: "F5",           keyCode: 96,  modifiers: []),
        Macro(id: "address",    title: "Ctrl+L",       keyCode: 37,  modifiers: .command),
        Macro(id: "back",       title: "Alt+←",        keyCode: 123, modifiers: .option),
        Macro(id: "forward",    title: "Alt+→",        keyCode: 124, modifiers: .option),
        Macro(id: "zoom-in",    title: "Ctrl++",       keyCode: 24,  modifiers: .command),
        Macro(id: "zoom-out",   title: "Ctrl+-",       keyCode: 27,  modifiers: .command),
        Macro(id: "zoom-reset", title: "Ctrl+0",       keyCode: 29,  modifiers: .command),
        Macro(id: "close",      title: "Ctrl+W",       keyCode: 13,  modifiers: .command),
        Macro(id: "quit",       title: "Alt+F4",       keyCode: 118, modifiers: .option),
        Macro(id: "appswitch",  title: "Alt+Tab",      keyCode: 48,  modifiers: .option),
        Macro(id: "task-manager", title: "Ctrl+Shift+Esc", keyCode: 53, modifiers: [.command, .shift]),
        Macro(id: "start",      title: "Win",          keyCode: 256, modifiers: []),
        Macro(id: "escape",     title: "Esc",          keyCode: 53,  modifiers: []),
        Macro(id: "return",     title: "⏎",            keyCode: 36,  modifiers: []),
    ]
}
