import Foundation
import MacCastKit

/// Writes Peering's hooks into Claude Code's settings, and takes them out again. Only ever called after the person said yes.
enum TerminalHookInstaller {
    enum Failure: LocalizedError {
        case unreadableSettings
        case unexpectedShape(String)

        var errorDescription: String? {
            switch self {
            case .unreadableSettings:
                String(localized: "Claude Code's settings.json is not valid JSON, so Peering left it alone.")
            case .unexpectedShape(let key):
                String(localized: "Claude Code's settings.json has an unexpected “\(key)”, so Peering left it alone.")
            }
        }
    }

    static var supportDirectory: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent(Bundle.main.bundleIdentifier ?? "pl.dmq.peering.host", isDirectory: true)
    }

    static var scriptURL: URL { supportDirectory.appendingPathComponent(ClaudeHookSettings.commandName) }

    static var settingsURL: URL {
        URL(fileURLWithPath: NSHomeDirectory()).appendingPathComponent(".claude/settings.json")
    }

    /// The command Claude Code runs, quoted because the folder has a space in it.
    static var command: String { "\"\(scriptURL.path)\"" }

    static func isInstalled() -> Bool {
        guard let settings = try? readSettings() else { return false }
        return ClaudeHookSettings.isInstalled(in: settings)
    }

    static func install() throws {
        let updated = try mapSettings { try ClaudeHookSettings.installing(command: command, into: $0) }
        try writeScript()
        try write(updated)
    }

    static func uninstall() throws {
        let updated = try mapSettings { try ClaudeHookSettings.removing(from: $0) }
        try write(updated)
        try? FileManager.default.removeItem(at: scriptURL)
    }

    // MARK: - Files

    private static func mapSettings(_ change: ([String: Any]) throws -> [String: Any]) throws -> [String: Any] {
        do {
            return try change(readSettings())
        } catch ClaudeHookSettings.Failure.unexpectedShape(let key) {
            throw Failure.unexpectedShape(key)
        }
    }

    private static func readSettings() throws -> [String: Any] {
        guard let data = try? Data(contentsOf: settingsURL) else { return [:] }
        guard !data.isEmpty else { return [:] }
        guard let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw Failure.unreadableSettings
        }
        return object
    }

    /// Writes through a symlink, so a settings file kept in a dotfiles repo stays a link, and keeps one copy of what was there before the first change.
    private static func write(_ settings: [String: Any]) throws {
        let target = settingsURL.resolvingSymlinksInPath()
        let manager = FileManager.default
        try manager.createDirectory(at: target.deletingLastPathComponent(), withIntermediateDirectories: true)

        let backup = target.appendingPathExtension("peering-backup")
        if manager.fileExists(atPath: target.path), !manager.fileExists(atPath: backup.path) {
            try manager.copyItem(at: target, to: backup)
        }
        let permissions = (try? manager.attributesOfItem(atPath: target.path))?[.posixPermissions]
        let data = try JSONSerialization.data(withJSONObject: settings, options: [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes])
        try data.write(to: target, options: .atomic)
        if let permissions { try manager.setAttributes([.posixPermissions: permissions], ofItemAtPath: target.path) }
    }

    /// Silent when Peering is not running, so Claude Code falls back to its own prompt.
    private static func writeScript() throws {
        let script = """
        #!/bin/sh
        # Passes a Claude Code hook to Peering for Mac and prints the answer. Installed by Peering, removed with it.
        socket="\(TerminalHookServer.socketURL.path)"
        [ -S "$socket" ] || exit 0
        { cat; echo; } | /usr/bin/nc -U "$socket"
        """
        try FileManager.default.createDirectory(at: supportDirectory, withIntermediateDirectories: true)
        try Data((script + "\n").utf8).write(to: scriptURL, options: .atomic)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: scriptURL.path)
    }
}
