#if DEBUG
import Foundation

/// Writes what a Mac terminal received and when its size was set, to Documents/terminal-trace.jsonl,
/// so a garbled screen can be replayed offline in the order the phone saw it.
enum TerminalTrace {
    private nonisolated static let url = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
        .appendingPathComponent("terminal-trace.jsonl")
    private nonisolated static let queue = DispatchQueue(label: "terminal-trace")

    static func write(_ record: [String: Any]) {
        guard UserDefaults.standard.bool(forKey: "Peering.traceTerminal") else { return }
        var record = record
        record["t"] = Date().timeIntervalSince1970
        guard let data = try? JSONSerialization.data(withJSONObject: record) else { return }
        queue.async {
            if !FileManager.default.fileExists(atPath: url.path) { FileManager.default.createFile(atPath: url.path, contents: nil) }
            guard let handle = try? FileHandle(forWritingTo: url) else { return }
            handle.seekToEndOfFile()
            handle.write(data + Data("\n".utf8))
            try? handle.close()
        }
    }
}
#endif
