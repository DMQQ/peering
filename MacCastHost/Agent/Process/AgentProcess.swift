import Darwin
import Foundation

final class AgentProcess: @unchecked Sendable {
    struct Launch {
        /// `codex exec` hangs on an open stdin pipe, so it gets /dev/null; Claude needs the pipe.
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

    var onLine: (@Sendable (String) -> Void)?
    var onStderrLine: (@Sendable (String) -> Void)?
    var onExit: (@Sendable (Int32) -> Void)?
    /// A line passed the size ceiling and was dropped.
    var onDiscardedLine: (@Sendable () -> Void)?

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
    private var dropping: Set<Stream> = []
    private(set) var isRunning = false

    /// Ceiling so a malformed stream cannot grow the buffer without bound.
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

        // Handler set before run so an instant death is still heard.
        process.terminationHandler = { [weak self] finished in
            guard let self else { return }
            self.drain()
            let status = finished.terminationStatus
            self.lock.withLock { self.isRunning = false }
            self.onExit?(status)
        }

        watch(stdoutPipe, as: .stdout)
        watch(stderrPipe, as: .stderr)

        try process.run()
        lock.withLock { isRunning = true }
    }

    /// Closes stdin first (stream-json CLIs exit cleanly on EOF), then signals; `terminate()` reaches only the child, not grandchildren.
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

    /// Serial queue so two prompts cannot interleave into one line.
    func write(line: String) {
        let data = Data(line.utf8) + [0x0A]
        writeQueue.async { [weak self] in
            guard let self else { return }
            try? self.stdinPipe.fileHandleForWriting.write(contentsOf: data)
        }
    }

    // MARK: - Reading

    /// An empty read is EOF, and a handler left in place after it fires in a tight loop until the process is reaped.
    private func watch(_ pipe: Pipe, as stream: Stream) {
        pipe.fileHandleForReading.readabilityHandler = { [weak self] handle in
            let data = handle.availableData
            guard !data.isEmpty else {
                handle.readabilityHandler = nil
                return
            }
            self?.receive(data, from: stream)
        }
    }

    private func receive(_ data: Data, from stream: Stream) {
        var lines: [String] = []
        var droppedAnOversizedLine = false
        lock.withLock {
            var buffer = buffers[stream] ?? Data()
            var rest = data
            if dropping.contains(stream) {
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
            onDiscardedLine?()
        }
    }

    private func drain() {
        var lines: [(String, Stream)] = []
        // Handlers go first so nothing reads the pipe while the remainder is taken.
        stdoutPipe.fileHandleForReading.readabilityHandler = nil
        stderrPipe.fileHandleForReading.readabilityHandler = nil
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
