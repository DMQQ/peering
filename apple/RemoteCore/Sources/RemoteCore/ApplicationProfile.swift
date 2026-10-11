import Foundation

/// A shortcut worth offering for a particular application, in the shared module so it can be tested without a UI.
///
/// `detail` gives the reason to press a key: "⌃C" is a keyboard fact, "interrupt what is running" is the purpose.
public struct ApplicationAction: Sendable, Hashable, Identifiable {
    /// Stable across releases, because the client remembers which of these a user has pinned.
    public let id: String
    public let title: String
    public let detail: String
    public let label: String
    /// A macOS virtual keycode, the values `CGEvent` takes, not a USB HID usage and not a
    /// character. The same convention every other keycode in this module uses.
    public let keyCode: UInt16
    public let modifiers: Modifiers

    public init(
        id: String,
        title: String,
        detail: String,
        label: String? = nil,
        keyCode: UInt16,
        modifiers: Modifiers
    ) {
        self.id = id
        self.title = title
        self.detail = detail
        self.label = label ?? detail
        self.keyCode = keyCode
        self.modifiers = modifiers
    }
}

public struct ApplicationProfile: Sendable, Hashable, Identifiable {
    public var id: String { bundleID }
    public let bundleID: String
    /// The heading to show: not the running app's localised name, which arrives with the catalogue in any language.
    public let name: String
    public let actions: [ApplicationAction]

    public init(bundleID: String, name: String, actions: [ApplicationAction]) {
        self.bundleID = bundleID
        self.name = name
        self.actions = actions
    }
}

/// The applications the app has something particular to say about.
/// A lookup table rather than a protocol; adding an application is adding a row.
public enum ApplicationActions {
    /// `nil` when there is nothing special to offer; an unknown app keeps the client's default macros.
    public static func profile(forBundleID bundleID: String?) -> ApplicationProfile? {
        guard let bundleID else { return nil }
        return profiles[bundleID]
    }

    public static var known: [ApplicationProfile] { Array(profiles.values) }

    private static let profiles: [String: ApplicationProfile] = {
        var table: [String: ApplicationProfile] = [:]
        for profile in all { table[profile.bundleID] = profile }
        return table
    }()

    private static let all: [ApplicationProfile] = [
        ApplicationProfile(
            bundleID: "com.apple.Terminal",
            name: "Terminal",
            actions: [
                ApplicationAction(id: "terminal.interrupt", title: "⌃C", detail: "Interrupt what is running", label: "Stop", keyCode: 8, modifiers: .control),
                ApplicationAction(id: "terminal.eof", title: "⌃D", detail: "End input, or close the shell", label: "EOF", keyCode: 2, modifiers: .control),
                ApplicationAction(id: "terminal.clear", title: "⌃L", detail: "Clear the screen", label: "Clear", keyCode: 37, modifiers: .control),
                ApplicationAction(id: "terminal.history", title: "⌃R", detail: "Search command history", label: "History", keyCode: 15, modifiers: .control),
                ApplicationAction(id: "terminal.start", title: "⌃A", detail: "Jump to the start of the line", label: "Start", keyCode: 0, modifiers: .control),
                ApplicationAction(id: "terminal.end", title: "⌃E", detail: "Jump to the end of the line", label: "End", keyCode: 14, modifiers: .control),
                ApplicationAction(id: "terminal.killline", title: "⌃U", detail: "Delete back to the start", label: "Kill line", keyCode: 32, modifiers: .control),
                ApplicationAction(id: "terminal.deleteword", title: "⌃W", detail: "Delete the word behind", label: "Del word", keyCode: 13, modifiers: .control),
                ApplicationAction(id: "terminal.clearbuffer", title: "⌘K", detail: "Clear the scrollback", label: "Scrollback", keyCode: 40, modifiers: .command),
                ApplicationAction(id: "terminal.newtab", title: "⌘T", detail: "New tab", label: "New tab", keyCode: 17, modifiers: .command),
            ]
        ),
        ApplicationProfile(
            bundleID: "com.mitchellh.ghostty",
            name: "Ghostty",
            actions: [
                ApplicationAction(id: "ghostty.interrupt", title: "⌃C", detail: "Interrupt what is running", label: "Stop", keyCode: 8, modifiers: .control),
                ApplicationAction(id: "ghostty.eof", title: "⌃D", detail: "End input, or close the shell", label: "EOF", keyCode: 2, modifiers: .control),
                ApplicationAction(id: "ghostty.clear", title: "⌃L", detail: "Clear the screen", label: "Clear", keyCode: 37, modifiers: .control),
                ApplicationAction(id: "ghostty.history", title: "⌃R", detail: "Search command history", label: "History", keyCode: 15, modifiers: .control),
                ApplicationAction(id: "ghostty.start", title: "⌃A", detail: "Jump to the start of the line", label: "Start", keyCode: 0, modifiers: .control),
                ApplicationAction(id: "ghostty.end", title: "⌃E", detail: "Jump to the end of the line", label: "End", keyCode: 14, modifiers: .control),
                ApplicationAction(id: "ghostty.killline", title: "⌃U", detail: "Delete back to the start", label: "Kill line", keyCode: 32, modifiers: .control),
                ApplicationAction(id: "ghostty.deleteword", title: "⌃W", detail: "Delete the word behind", label: "Del word", keyCode: 13, modifiers: .control),
                ApplicationAction(id: "ghostty.clearbuffer", title: "⌘K", detail: "Clear the scrollback", label: "Scrollback", keyCode: 40, modifiers: .command),
                ApplicationAction(id: "ghostty.newtab", title: "⌘T", detail: "New tab", label: "New tab", keyCode: 17, modifiers: .command),
            ]
        ),
        ApplicationProfile(
            bundleID: "com.googlecode.iterm2",
            name: "iTerm",
            actions: [
                ApplicationAction(id: "iterm.interrupt", title: "⌃C", detail: "Interrupt what is running", label: "Stop", keyCode: 8, modifiers: .control),
                ApplicationAction(id: "iterm.eof", title: "⌃D", detail: "End input, or close the shell", label: "EOF", keyCode: 2, modifiers: .control),
                ApplicationAction(id: "iterm.clear", title: "⌃L", detail: "Clear the screen", label: "Clear", keyCode: 37, modifiers: .control),
                ApplicationAction(id: "iterm.history", title: "⌃R", detail: "Search command history", label: "History", keyCode: 15, modifiers: .control),
                ApplicationAction(id: "iterm.start", title: "⌃A", detail: "Jump to the start of the line", label: "Start", keyCode: 0, modifiers: .control),
                ApplicationAction(id: "iterm.end", title: "⌃E", detail: "Jump to the end of the line", label: "End", keyCode: 14, modifiers: .control),
                ApplicationAction(id: "iterm.deleteword", title: "⌃W", detail: "Delete the word behind", label: "Del word", keyCode: 13, modifiers: .control),
                ApplicationAction(id: "iterm.split", title: "⌘D", detail: "Split the pane", label: "Split", keyCode: 2, modifiers: .command),
            ]
        ),
        ApplicationProfile(
            bundleID: "com.apple.dt.Xcode",
            name: "Xcode",
            actions: [
                ApplicationAction(id: "xcode.build", title: "⌘B", detail: "Build", label: "Build", keyCode: 11, modifiers: .command),
                ApplicationAction(id: "xcode.run", title: "⌘R", detail: "Run", label: "Run", keyCode: 15, modifiers: .command),
                ApplicationAction(id: "xcode.stop", title: "⌘.", detail: "Stop", label: "Stop", keyCode: 47, modifiers: .command),
                ApplicationAction(id: "xcode.openquickly", title: "⌘⇧O", detail: "Open quickly", label: "Open", keyCode: 31, modifiers: [.command, .shift]),
                ApplicationAction(id: "xcode.clean", title: "⌘⇧K", detail: "Clean the build folder", label: "Clean", keyCode: 40, modifiers: [.command, .shift]),
                ApplicationAction(id: "xcode.issues", title: "⌘⇧M", detail: "Show the issue navigator", label: "Issues", keyCode: 46, modifiers: [.command, .shift]),
            ]
        ),
        ApplicationProfile(
            bundleID: "com.microsoft.VSCode",
            name: "Visual Studio Code",
            actions: [
                ApplicationAction(id: "vscode.commands", title: "⌘⇧P", detail: "Command palette", label: "Commands", keyCode: 35, modifiers: [.command, .shift]),
                ApplicationAction(id: "vscode.quickopen", title: "⌘P", detail: "Go to file", label: "Go to file", keyCode: 35, modifiers: .command),
                ApplicationAction(id: "vscode.terminal", title: "⌃`", detail: "Toggle the terminal", label: "Terminal", keyCode: 50, modifiers: .control),
                ApplicationAction(id: "vscode.sidebar", title: "⌘B", detail: "Toggle the sidebar", label: "Sidebar", keyCode: 11, modifiers: .command),
                ApplicationAction(id: "vscode.saveall", title: "⌘⌥S", detail: "Save all", label: "Save all", keyCode: 1, modifiers: [.command, .option]),
            ]
        ),
        ApplicationProfile(
            bundleID: "com.apple.Safari",
            name: "Safari",
            actions: [
                ApplicationAction(id: "safari.newtab", title: "⌘T", detail: "New tab", label: "New tab", keyCode: 17, modifiers: .command),
                ApplicationAction(id: "safari.location", title: "⌘L", detail: "Go to the address field", label: "Address", keyCode: 37, modifiers: .command),
                ApplicationAction(id: "safari.reload", title: "⌘R", detail: "Reload", label: "Reload", keyCode: 15, modifiers: .command),
                ApplicationAction(id: "safari.back", title: "⌘[", detail: "Back", label: "Back", keyCode: 33, modifiers: .command),
                ApplicationAction(id: "safari.forward", title: "⌘]", detail: "Forward", label: "Forward", keyCode: 30, modifiers: .command),
                ApplicationAction(id: "safari.reader", title: "⌘⇧R", detail: "Reader view", label: "Reader", keyCode: 15, modifiers: [.command, .shift]),
            ]
        ),
        ApplicationProfile(
            bundleID: "com.apple.finder",
            name: "Finder",
            actions: [
                ApplicationAction(id: "finder.goto", title: "⌘⇧G", detail: "Go to a folder by path", label: "Go to", keyCode: 5, modifiers: [.command, .shift]),
                ApplicationAction(id: "finder.newfolder", title: "⌘⇧N", detail: "New folder", label: "Folder", keyCode: 45, modifiers: [.command, .shift]),
                ApplicationAction(id: "finder.trash", title: "⌘⌫", detail: "Move to the bin", label: "Bin", keyCode: 51, modifiers: .command),
                ApplicationAction(id: "finder.hidden", title: "⌘⇧.", detail: "Show hidden files", label: "Hidden", keyCode: 47, modifiers: [.command, .shift]),
                ApplicationAction(id: "finder.parent", title: "⌘↑", detail: "Enclosing folder", label: "Up", keyCode: 126, modifiers: .command),
            ]
        ),
    ]
}
