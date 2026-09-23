import Foundation

/// What a command the user typed is about to run, where that changes how the terminal should look.
///
/// **A full-screen program is laid out for eighty columns, and on a phone held upright only the
/// smallest type size holds all eighty.** So the size is set when such a program is asked for,
/// rather than left to be found in a menu while the user is looking at a screen two-thirds of which
/// they cannot read. What the app can see is what was typed through it: a program started from the
/// Mac's own keyboard is not this end's business.
public enum TerminalProgram {
    /// The ones that draw a screen of their own rather than printing lines.
    ///
    /// A list rather than one special case, because the reason has nothing to do with any of them:
    /// they all address a grid they expect to be a terminal's whole width. A shell command that
    /// prints is not in it, because its output is read at a comfortable size and the size is the
    /// user's to keep.
    private static let fullScreen: Set<String> = [
        "claude", "vim", "vi", "nvim", "view", "top", "htop", "btop", "less", "more", "man", "tmux",
        "screen", "emacs", "nano", "pico", "w3m", "lynx", "irssi", "weechat",
    ]

    /// Wrappers that are not the program, and are skipped to find what is being run.
    private static let wrappers: Set<String> = ["sudo", "doas", "env", "command", "nohup", "time"]

    /// Whether this command line starts something that lays itself out for a full terminal.
    ///
    /// Only the program is looked at, and only the first one that is not a wrapper: `grep vim`
    /// searches for the word, and `less vim.txt` is a pager either way, so what the words after it
    /// say about it is not this question.
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
