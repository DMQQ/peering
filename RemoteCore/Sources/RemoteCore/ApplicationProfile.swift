import Foundation

/// A shortcut worth offering for a particular application.
///
/// Deliberately the same shape as the client's own macro buttons — a title, a keycode and a set
/// of modifiers — but stated here in the shared module so it can be tested without a UI, and so
/// the knowledge of what a terminal wants is not buried in a view.
///
/// `detail` exists because a keycode is not self-explanatory. "⌃C" is a fact about a keyboard;
/// "interrupt what is running" is the reason anyone would press it, and the client has room to
/// show one of them.
public struct ApplicationAction: Sendable, Hashable, Identifiable {
    /// Stable across releases, because the client remembers which of these a user has pinned.
    public let id: String
    public let title: String
    public let detail: String
    /// A macOS virtual keycode — the values `CGEvent` takes — not a USB HID usage and not a
    /// character. The same convention every other keycode in this module uses.
    public let keyCode: UInt16
    public let modifiers: Modifiers

    public init(id: String, title: String, detail: String, keyCode: UInt16, modifiers: Modifiers) {
        self.id = id
        self.title = title
        self.detail = detail
        self.keyCode = keyCode
        self.modifiers = modifiers
    }
}

/// What the app knows about one application, and what it can therefore offer.
public struct ApplicationProfile: Sendable, Hashable, Identifiable {
    public var id: String { bundleID }
    public let bundleID: String
    /// The name to show above the actions. Not read from the running app's localised name:
    /// that arrives with the catalogue and can be in any language, and this one is a heading.
    public let name: String
    public let actions: [ApplicationAction]

    public init(bundleID: String, name: String, actions: [ApplicationAction]) {
        self.bundleID = bundleID
        self.name = name
        self.actions = actions
    }
}

/// The applications the app has something particular to say about, and how to ask.
///
/// A lookup rather than a protocol, on purpose. There is exactly one way to decide this today —
/// by bundle identifier — and one implementation behind an interface is a seam that costs
/// indirection and buys nothing. When a second way appears, the shape to add is a second
/// argument here and a second line in ``profile(forBundleID:)``; the callers do not change.
///
/// The table is data rather than code so that adding an application is adding a row. That is the
/// whole point of the thing: the client's own macro bar is a fixed list of the keys everyone
/// wants, and this is the place for the keys that only make sense once we know what is on the
/// screen.
public enum ApplicationActions {
    /// The profile for a bundle identifier, or `nil` when there is nothing special to offer.
    ///
    /// Nil is the common case and not a failure. An app nobody has thought about keeps the
    /// client's default macros, which are the ones that work everywhere — and a profile that
    /// guessed at an unknown application would be worse than no profile at all.
    public static func profile(forBundleID bundleID: String?) -> ApplicationProfile? {
        guard let bundleID else { return nil }
        return profiles[bundleID]
    }

    /// Every application with a profile, for tests and for anything that wants to list them.
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
                ApplicationAction(id: "terminal.interrupt", title: "⌃C", detail: "Interrupt what is running", keyCode: 8, modifiers: .control),
                ApplicationAction(id: "terminal.eof", title: "⌃D", detail: "End input, or close the shell", keyCode: 2, modifiers: .control),
                ApplicationAction(id: "terminal.clear", title: "⌃L", detail: "Clear the screen", keyCode: 37, modifiers: .control),
                ApplicationAction(id: "terminal.history", title: "⌃R", detail: "Search command history", keyCode: 15, modifiers: .control),
                ApplicationAction(id: "terminal.start", title: "⌃A", detail: "Jump to the start of the line", keyCode: 0, modifiers: .control),
                ApplicationAction(id: "terminal.end", title: "⌃E", detail: "Jump to the end of the line", keyCode: 14, modifiers: .control),
                ApplicationAction(id: "terminal.killline", title: "⌃U", detail: "Delete back to the start", keyCode: 32, modifiers: .control),
                ApplicationAction(id: "terminal.deleteword", title: "⌃W", detail: "Delete the word behind", keyCode: 13, modifiers: .control),
                ApplicationAction(id: "terminal.clearbuffer", title: "⌘K", detail: "Clear the scrollback", keyCode: 40, modifiers: .command),
                ApplicationAction(id: "terminal.newtab", title: "⌘T", detail: "New tab", keyCode: 17, modifiers: .command),
            ]
        ),
        // iTerm2 asks the same things of a shell and gives the same answers; the one difference
        // anyone notices is that its clear-the-scrollback is the same keystroke.
        ApplicationProfile(
            bundleID: "com.googlecode.iterm2",
            name: "iTerm",
            actions: [
                ApplicationAction(id: "iterm.interrupt", title: "⌃C", detail: "Interrupt what is running", keyCode: 8, modifiers: .control),
                ApplicationAction(id: "iterm.eof", title: "⌃D", detail: "End input, or close the shell", keyCode: 2, modifiers: .control),
                ApplicationAction(id: "iterm.clear", title: "⌃L", detail: "Clear the screen", keyCode: 37, modifiers: .control),
                ApplicationAction(id: "iterm.history", title: "⌃R", detail: "Search command history", keyCode: 15, modifiers: .control),
                ApplicationAction(id: "iterm.start", title: "⌃A", detail: "Jump to the start of the line", keyCode: 0, modifiers: .control),
                ApplicationAction(id: "iterm.end", title: "⌃E", detail: "Jump to the end of the line", keyCode: 14, modifiers: .control),
                ApplicationAction(id: "iterm.deleteword", title: "⌃W", detail: "Delete the word behind", keyCode: 13, modifiers: .control),
                ApplicationAction(id: "iterm.split", title: "⌘D", detail: "Split the pane", keyCode: 2, modifiers: .command),
            ]
        ),
        ApplicationProfile(
            bundleID: "com.apple.dt.Xcode",
            name: "Xcode",
            actions: [
                ApplicationAction(id: "xcode.build", title: "⌘B", detail: "Build", keyCode: 11, modifiers: .command),
                ApplicationAction(id: "xcode.run", title: "⌘R", detail: "Run", keyCode: 15, modifiers: .command),
                ApplicationAction(id: "xcode.stop", title: "⌘.", detail: "Stop", keyCode: 47, modifiers: .command),
                ApplicationAction(id: "xcode.openquickly", title: "⌘⇧O", detail: "Open quickly", keyCode: 31, modifiers: [.command, .shift]),
                ApplicationAction(id: "xcode.clean", title: "⌘⇧K", detail: "Clean the build folder", keyCode: 40, modifiers: [.command, .shift]),
                ApplicationAction(id: "xcode.issues", title: "⌘⇧M", detail: "Show the issue navigator", keyCode: 46, modifiers: [.command, .shift]),
            ]
        ),
        ApplicationProfile(
            bundleID: "com.microsoft.VSCode",
            name: "Visual Studio Code",
            actions: [
                ApplicationAction(id: "vscode.commands", title: "⌘⇧P", detail: "Command palette", keyCode: 35, modifiers: [.command, .shift]),
                ApplicationAction(id: "vscode.quickopen", title: "⌘P", detail: "Go to file", keyCode: 35, modifiers: .command),
                ApplicationAction(id: "vscode.terminal", title: "⌃`", detail: "Toggle the terminal", keyCode: 50, modifiers: .control),
                ApplicationAction(id: "vscode.sidebar", title: "⌘B", detail: "Toggle the sidebar", keyCode: 11, modifiers: .command),
                ApplicationAction(id: "vscode.saveall", title: "⌘⌥S", detail: "Save all", keyCode: 1, modifiers: [.command, .option]),
            ]
        ),
        ApplicationProfile(
            bundleID: "com.apple.Safari",
            name: "Safari",
            actions: [
                ApplicationAction(id: "safari.newtab", title: "⌘T", detail: "New tab", keyCode: 17, modifiers: .command),
                ApplicationAction(id: "safari.location", title: "⌘L", detail: "Go to the address field", keyCode: 37, modifiers: .command),
                ApplicationAction(id: "safari.reload", title: "⌘R", detail: "Reload", keyCode: 15, modifiers: .command),
                ApplicationAction(id: "safari.back", title: "⌘[", detail: "Back", keyCode: 33, modifiers: .command),
                ApplicationAction(id: "safari.forward", title: "⌘]", detail: "Forward", keyCode: 30, modifiers: .command),
                ApplicationAction(id: "safari.reader", title: "⌘⇧R", detail: "Reader view", keyCode: 15, modifiers: [.command, .shift]),
            ]
        ),
        ApplicationProfile(
            bundleID: "com.apple.finder",
            name: "Finder",
            actions: [
                ApplicationAction(id: "finder.goto", title: "⌘⇧G", detail: "Go to a folder by path", keyCode: 5, modifiers: [.command, .shift]),
                ApplicationAction(id: "finder.newfolder", title: "⌘⇧N", detail: "New folder", keyCode: 45, modifiers: [.command, .shift]),
                ApplicationAction(id: "finder.trash", title: "⌘⌫", detail: "Move to the bin", keyCode: 51, modifiers: .command),
                ApplicationAction(id: "finder.hidden", title: "⌘⇧.", detail: "Show hidden files", keyCode: 47, modifiers: [.command, .shift]),
                ApplicationAction(id: "finder.parent", title: "⌘↑", detail: "Enclosing folder", keyCode: 126, modifiers: .command),
            ]
        ),
    ]
}
