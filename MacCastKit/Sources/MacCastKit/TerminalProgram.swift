import Foundation

/// A full-screen program lays out for eighty columns, and only the smallest type size holds them on an upright phone, so the size is set when one is asked for. Programs started from the Mac's keyboard are not this end's business.
public enum TerminalProgram {
    /// The ones that draw a screen of their own rather than printing lines.
    private static let fullScreen: Set<String> = [
        "claude", "codex", "opencode", "hermes", "gemini", "vim", "vi", "nvim", "view", "top", "htop", "btop", "less", "more", "man", "tmux",
        "screen", "emacs", "nano", "pico", "w3m", "lynx", "irssi", "weechat",
    ]

    private static let wrappers: Set<String> = ["sudo", "doas", "env", "command", "nohup", "time"]

    /// Only the first non-wrapper word is looked at: `grep vim` is not vim.
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
