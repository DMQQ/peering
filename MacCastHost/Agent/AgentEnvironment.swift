import Foundation

/// The environment and the binary a chat's CLI needs, taken from the user's own login shell.
///
/// The host is a Finder-launched app, so its own environment is not the one a Terminal gives a
/// command: no `PATH` beyond the system's, no variable a dotfile exports, no API key that was
/// exported in one. A CLI started with the app's environment would be a CLI the user has never
/// run, which is why the terminal panel already spawns a login shell and why this does the same
/// before cutting the shell out of the picture.
///
/// Resolved once and kept: the answers are a property of the machine's shell setup and do not
/// change while the app runs.
final class AgentEnvironment: @unchecked Sendable {
    static let shared = AgentEnvironment()

    private let lock = NSLock()
    private var cachedVariables: [String: String]?
    private var cachedBinaries: [String: String] = [:]

    /// The variables a login shell would give a command, plus this app's own corrections.
    func variables() -> [String: String] {
        lock.lock()
        if let cached = cachedVariables {
            lock.unlock()
            return cached
        }
        lock.unlock()

        var environment = Self.parseEnvironment(Self.loginShellOutput(script: "/usr/bin/env -0")) ?? [:]
        // The three the CLIs' own credential and config lookup hangs on, filled in when a shell
        // startup file said nothing, which is the normal case for HOME in a login shell.
        environment["HOME"] = environment["HOME"] ?? NSHomeDirectory()
        environment["USER"] = environment["USER"] ?? NSUserName()
        environment["LOGNAME"] = environment["LOGNAME"] ?? NSUserName()
        environment["SHELL"] = environment["SHELL"] ?? Self.loginShellPath()
        if environment["PATH"]?.isEmpty != false {
            environment["PATH"] = ProcessInfo.processInfo.environment["PATH"] ?? "/usr/bin:/bin:/usr/sbin:/sbin"
        }
        // Output is parsed, never looked at, and a CLI that decides to draw a spinner is a CLI
        // whose every byte this side would have to throw away.
        environment["NO_COLOR"] = "1"

        lock.lock()
        cachedVariables = environment
        lock.unlock()
        return environment
    }

    /// Where a command lives, as the user's login shell would find it.
    ///
    /// The absolute path is what gets spawned, never the shell: a dotfile that prints a banner
    /// would put that banner on the stdout this side parses as JSONL, and one stray line is a
    /// session that cannot start.
    func binary(named name: String) -> String? {
        guard !name.isEmpty, name.allSatisfy({ $0.isLetter || $0.isNumber || $0 == "-" || $0 == "_" }) else {
            return nil
        }
        lock.lock()
        if let cached = cachedBinaries[name] {
            lock.unlock()
            return cached.isEmpty ? nil : cached
        }
        lock.unlock()

        // A banner before the answer is the normal case, so the answer is the last line that is a
        // path, not the first line.
        let output = Self.loginShellOutput(script: "command -v \(name)")
        let path = output?
            .split(separator: "\n")
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .last { $0.hasPrefix("/") }

        lock.lock()
        cachedBinaries[name] = path ?? ""
        lock.unlock()
        return path
    }

    /// The user's login shell, from the password database first.
    static func loginShellPath() -> String {
        if let entry = getpwuid(getuid()), let shell = entry.pointee.pw_shell {
            let path = String(cString: shell)
            if !path.isEmpty { return path }
        }
        return ProcessInfo.processInfo.environment["SHELL"] ?? "/bin/zsh"
    }

    // MARK: - The shell itself

    /// Runs a command in a login+interactive shell, with the deadline the agent probe uses.
    ///
    /// The marker exists because startup files may print whatever they like before the command
    /// runs; everything of interest is after the marker, and a shell that cannot answer in time
    /// answers nothing rather than holding a session open.
    private static func loginShellOutput(script: String, seconds: Int = 6) -> String? {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: loginShellPath())
        process.arguments = ["-l", "-i", "-c", "printf '<PEERING>\\n'; \(script)"]
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = FileHandle.nullDevice
        process.standardInput = FileHandle.nullDevice
        do { try process.run() } catch { return nil }

        let deadline = DispatchTime.now() + .seconds(seconds)
        let group = DispatchGroup()
        group.enter()
        DispatchQueue.global().async {
            process.waitUntilExit()
            group.leave()
        }
        if group.wait(timeout: deadline) == .timedOut {
            process.terminate()
            return nil
        }

        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        // Decoded leniently: a banner in some other encoding must not cost the environment behind it.
        let text = String(decoding: data, as: UTF8.self)
        guard let marker = text.range(of: "<PEERING>\n") else { return text.isEmpty ? nil : text }
        return String(text[marker.upperBound...])
    }

    /// `env -0`'s output, back into pairs.
    ///
    /// NUL separated because a variable's value may contain newlines. Only chunks that look like
    /// `KEY=value` count, which is what keeps a shell banner that ran into the first variable on
    /// the same chunk from becoming a variable named after half a sentence.
    private static func parseEnvironment(_ text: String?) -> [String: String]? {
        guard let text else { return nil }
        var variables: [String: String] = [:]
        for chunk in text.split(separator: "\u{0}", omittingEmptySubsequences: true) {
            guard let equals = chunk.firstIndex(of: "=") else { continue }
            let key = String(chunk[chunk.startIndex..<equals])
            guard !key.isEmpty,
                  key.allSatisfy({ $0.isLetter || $0.isNumber || $0 == "_" }),
                  key.first?.isNumber != true
            else { continue }
            variables[key] = String(chunk[chunk.index(after: equals)...])
        }
        return variables.isEmpty ? nil : variables
    }
}
