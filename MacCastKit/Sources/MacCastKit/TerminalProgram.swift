import Foundation

/// What a command the user typed is about to run, where that changes how the terminal should look.
///
/// A full-screen program lays itself out for eighty columns, and only the smallest type size holds
/// all eighty on a phone held upright, so the size is set when one is asked for.
///
/// A program started from the Mac's own keyboard is not this end's business.
public enum TerminalProgram {
    /// The ones that draw a screen of their own rather than printing lines: they all address a grid
    /// they expect to be a terminal's whole width.
    private static let fullScreen: Set<String> = [
        "claude", "codex", "opencode", "hermes", "gemini", "vim", "vi", "nvim", "view", "top", "htop", "btop", "less", "more", "man", "tmux",
        "screen", "emacs", "nano", "pico", "w3m", "lynx", "irssi", "weechat",
    ]

    /// Wrappers that are not the program, and are skipped to find what is being run.
    private static let wrappers: Set<String> = ["sudo", "doas", "env", "command", "nohup", "time"]

    /// Whether this command line starts something that lays itself out for a full terminal.
    ///
    /// Only the first word that is not a wrapper is looked at: `grep vim` searches for the word
    /// rather than starting vim.
    public static func prefersSmallText(_ command: String) -> Bool {
        for word in words(of: command) where !wrappers.contains(word) {
            return fullScreen.contains(word)
        }
        return false
    }

    /// The words of a command line, lowercased, with any path taken off the front and any
    /// `VAR=value` dropped, because `FOO=1 /usr/bin/claude` runs `claude`.
    private static func words(of command: String) -> [String] {
        command
            .split(whereSeparator: { $0 == " " || $0 == "\t" })
            .map { $0.lowercased() }
            .filter { !$0.contains("=") }
            .map { $0.split(separator: "/").last.map(String.init) ?? $0 }
    }
}
