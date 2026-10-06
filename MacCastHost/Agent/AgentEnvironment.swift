import Foundation

final class AgentEnvironment: @unchecked Sendable {
    static let shared = AgentEnvironment()

    private let lock = NSLock()
    private var cachedVariables: [String: String]?
    private var cachedBinaries: [String: String] = [:]

    func variables() -> [String: String] {
        lock.lock()
        if let cached = cachedVariables {
            lock.unlock()
            return cached
        }
        lock.unlock()

        var environment = Self.parseEnvironment(Self.loginShellOutput(script: "/usr/bin/env -0")) ?? [:]
        environment["HOME"] = environment["HOME"] ?? NSHomeDirectory()
        environment["USER"] = environment["USER"] ?? NSUserName()
        environment["LOGNAME"] = environment["LOGNAME"] ?? NSUserName()
        environment["SHELL"] = environment["SHELL"] ?? Self.loginShellPath()
        if environment["PATH"]?.isEmpty != false {
            environment["PATH"] = ProcessInfo.processInfo.environment["PATH"] ?? "/usr/bin:/bin:/usr/sbin:/sbin"
        }
        // Output is parsed, never shown, so the CLI must not draw a spinner.
        environment["NO_COLOR"] = "1"

        lock.lock()
        cachedVariables = environment
        lock.unlock()
        return environment
    }

    /// Spawned by absolute path, never via the shell: a dotfile banner would land in the JSONL stdout.
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

    static func loginShellPath() -> String {
        if let entry = getpwuid(getuid()), let shell = entry.pointee.pw_shell {
            let path = String(cString: shell)
            if !path.isEmpty { return path }
        }
        return ProcessInfo.processInfo.environment["SHELL"] ?? "/bin/zsh"
    }

    // MARK: - The shell itself

    /// Startup files may print before the command; only output after the marker counts.
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

    /// NUL separated because values may contain newlines; only `KEY=value` chunks count.
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
