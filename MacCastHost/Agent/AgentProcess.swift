import Darwin
import Foundation

/// One CLI process the host owns: how it starts, how its lines are read, how it is written to and
/// how it is stopped.
///
/// A peer of the terminal manager's `script` wrapping rather than a re-use of it: a PTY is exactly
/// what this must not be. The CLIs speak JSONL on plain pipes here, and a terminal's line
/// discipline, echo and signal behaviour would be an interpreter sitting between the parser and
/// its input.
final class AgentProcess: @unchecked Sendable {
    struct Launch {
        /// What the child gets on stdin.
        ///
        /// Not cosmetic: `codex exec` reads stdin whenever it is not a terminal, and an open pipe
        /// that never closes hangs it before it does anything. Claude needs the pipe, because its
        /// stream-json input *is* stdin; Codex gets `/dev/null`, which reads as the immediate EOF
        /// it is waiting for.
        enum Input {
            case pipe
            case null
        }

        let binary: String
        let arguments: [String]
        let directory: URL
        let environment: [String: String]
        var input: Input = .pipe
    }

    /// A complete line, decoded. Called on the reading thread; the adapter hands work onward.
    var onLine: (@Sendable (String) -> Void)?
    var onStderrLine: (@Sendable (String) -> Void)?
    /// The process ended, by its own choice or by ``stop()``.
    var onExit: (@Sendable (Int32) -> Void)?

    private enum Stream: Hashable {
        case stdout
        case stderr
    }

    private let process = Process()
    private let stdinPipe = Pipe()
    private let stdoutPipe = Pipe()
    private let stderrPipe = Pipe()
    private let writeQueue = DispatchQueue(label: "pl.dmq.peering.host.agent.stdin")
    private let lock = NSLock()
    private var buffers: [Stream: Data] = [:]
    /// Streams currently inside a line that outgrew the buffer, whose remainder is being thrown
    /// away until the newline that ends it.
    private var dropping: Set<Stream> = []
    private(set) var isRunning = false

    /// How large a single line may grow before it is discarded to the next newline.
    ///
    /// A JSONL line is a tool result or a message, and Claude Code bounds the tool output it
    /// carries long before this; the ceiling exists so a malformed stream cannot grow the buffer
    /// until the host runs out of memory.
    private static let maximumLineBytes = 16 * 1024 * 1024

    // MARK: - Launching

    func start(_ launch: Launch) throws {
        process.executableURL = URL(fileURLWithPath: launch.binary)
        process.arguments = launch.arguments
        process.currentDirectoryURL = launch.directory
        process.environment = launch.environment
        process.standardInput = launch.input == .pipe ? stdinPipe : FileHandle.nullDevice
        process.standardOutput = stdoutPipe
        process.standardError = stderrPipe

        // The handler is set before the run: a CLI that dies immediately would otherwise have
        // nobody listening for the death, and a session would wait forever for an answer.
        process.terminationHandler = { [weak self] finished in
            guard let self else { return }
            self.drain()
            let status = finished.terminationStatus
            self.lock.withLock { self.isRunning = false }
            self.onExit?(status)
        }

        stdoutPipe.fileHandleForReading.readabilityHandler = { [weak self] handle in
            let data = handle.availableData
            guard !data.isEmpty else { return }
            self?.receive(data, from: .stdout)
        }
        stderrPipe.fileHandleForReading.readabilityHandler = { [weak self] handle in
            let data = handle.availableData
            guard !data.isEmpty else { return }
            self?.receive(data, from: .stderr)
        }

        try process.run()
        lock.withLock { isRunning = true }
    }

    /// Ends the process the way the CLI documents, then the way the system does.
    ///
    /// Closing stdin first is not a courtesy: a stream-json CLI finishes its work and exits on EOF,
    /// which is the difference between a session that stops and one killed mid-write. The signals
    /// behind it are for the times that fails. `Process` cannot put the child in its own process
    /// group, so `terminate()` reaches the child only; grandchildren are left to the system.
    func stop() {
        try? stdinPipe.fileHandleForWriting.close()
        DispatchQueue.global().asyncAfter(deadline: .now() + 3) { [weak self] in
            guard let self, self.lock.withLock({ self.isRunning }) else { return }
            self.process.terminate()
            DispatchQueue.global().asyncAfter(deadline: .now() + 5) { [weak self] in
                guard let self, self.lock.withLock({ self.isRunning }) else { return }
                if self.process.processIdentifier > 0 {
                    kill(self.process.processIdentifier, SIGKILL)
                }
            }
        }
    }

    // MARK: - Writing

    /// One line of input, on a serial queue so two prompts can never interleave into one corrupt
    /// line. `FileHandle.write(contentsOf:)` publishes all the bytes before it returns.
    func write(line: String) {
        var data = Data(line.utf8)
        data.append(0x0A)
        writeQueue.async { [weak self] in
            guard let self else { return }
            try? self.stdinPipe.fileHandleForWriting.write(contentsOf: data)
        }
    }

    // MARK: - Reading

    private func receive(_ data: Data, from stream: Stream) {
        var lines: [String] = []
        var droppedAnOversizedLine = false
        lock.withLock {
            var buffer = buffers[stream] ?? Data()
            var rest = data
            if dropping.contains(stream) {
                // Inside the overlong line's remainder: everything before the newline goes.
                guard let newline = rest.firstIndex(of: 0x0A) else { return }
                dropping.remove(stream)
                rest = rest[rest.index(after: newline)...]
            }
            buffer.append(rest)

            while let newline = buffer.firstIndex(of: 0x0A) {
                let line = buffer[buffer.startIndex..<newline]
                buffer.removeSubrange(buffer.startIndex...newline)
                // Decoded after the join, never before: a multi-byte scalar split across two reads
                // is one character here and garbage if each half is decoded alone.
                lines.append(String(decoding: line, as: UTF8.self))
            }
            if buffer.count > Self.maximumLineBytes {
                buffer.removeAll(keepingCapacity: true)
                dropping.insert(stream)
                droppedAnOversizedLine = true
            }
            buffers[stream] = buffer
        }
        for line in lines where !line.isEmpty {
            hand(line, from: stream)
        }
        if droppedAnOversizedLine {
            hand("A line from the agent was too long to read, and its remainder was discarded.", from: stream)
        }
    }

    /// Whatever arrived after the process ended but before the handlers were cleared.
    private func drain() {
        var lines: [(String, Stream)] = []
        lock.withLock {
            for stream in [Stream.stdout, .stderr] {
                let handle = stream == .stdout ? stdoutPipe.fileHandleForReading : stderrPipe.fileHandleForReading
                var buffer = buffers[stream] ?? Data()
                buffer.append(handle.readDataToEndOfFile())
                while let newline = buffer.firstIndex(of: 0x0A) {
                    let line = buffer[buffer.startIndex..<newline]
                    buffer.removeSubrange(buffer.startIndex...newline)
                    lines.append((String(decoding: line, as: UTF8.self), stream))
                }
                if !buffer.isEmpty {
                    lines.append((String(decoding: buffer, as: UTF8.self), stream))
                }
                buffers[stream] = Data()
            }
            stdoutPipe.fileHandleForReading.readabilityHandler = nil
            stderrPipe.fileHandleForReading.readabilityHandler = nil
        }
        for (line, stream) in lines where !line.isEmpty {
            hand(line, from: stream)
        }
    }

    private func hand(_ line: String, from stream: Stream) {
        switch stream {
        case .stdout: onLine?(line)
        case .stderr: onStderrLine?(line)
        }
    }
}
