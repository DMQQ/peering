import Foundation

/// A line-by-line record of what the picture was drawn at, for a flicker that cannot be caught by
/// looking at the code.
///
/// **Temporary.** It exists to answer one question: the arriving picture is occasionally drawn at
/// the wrong scale for a moment, and every candidate for that is a number that moves in a different
/// order depending on which of several racy paths ran. Reading the numbers in the order they were
/// written says which one it was, and nothing else can: the geometry is written from four files,
/// two of them while a movement is in flight, and no log the app keeps is precise enough to line
/// them up.
///
/// Written to the app's own container so it can be pulled over the cable with
/// `devicectl device copy from --domain-type appDataContainer`.
///
/// **Lock-guarded rather than main-actor**, because half of what it records is written on the video
/// queue: the moment a held frame is handed over is one of the events that matters, and it does not
/// happen on the main actor. The file is written at most four times a second for the same reason —
/// a movement writes sixty lines a second, and a file rewritten sixty times a second is work done
/// on the queue that is decoding the picture.
nonisolated enum PictureTrace {
    /// How many lines the file keeps, newest last.
    private static let limit = 4000
    /// The shortest gap between two writes to disk.
    private static let flushInterval: TimeInterval = 0.25

    private static let lock = NSLock()
    nonisolated(unsafe) private static var lines: [String] = []
    nonisolated(unsafe) private static var hasBegun = false
    nonisolated(unsafe) private static var startedAt = Date()
    nonisolated(unsafe) private static var lastFlush = Date.distantPast
    nonisolated(unsafe) private static var launches = 0

    private static let url: URL? = {
        guard let documents = FileManager.default.urls(
            for: .documentDirectory,
            in: .userDomainMask
        ).first else { return nil }
        return documents.appendingPathComponent("picture-trace.log")
    }()

    /// Records one moment, with the milliseconds since the trace began.
    ///
    /// The elapsed time rather than a clock time: everything here is about what happened within a
    /// few frames of something else, and a date does not say that at a glance.
    nonisolated static func write(_ line: String) {
        lock.withLock {
            let elapsed = Int(Date().timeIntervalSince(startedAt) * 1000)
            lines.append("\(elapsed) \(line)")
            let trimmed = lines.count > limit
            if trimmed { lines.removeFirst(lines.count - limit) }

            let now = Date()
            guard trimmed || now.timeIntervalSince(lastFlush) > flushInterval else { return }
            lastFlush = now
            flushLocked()
        }
    }

    nonisolated private static func flushLocked() {
        guard let url else { return }
        let text = lines.joined(separator: "\n") + "\n"
        try? text.write(to: url, atomically: true, encoding: .utf8)
    }

    /// Marks the start of a launch, and keeps what the last one wrote.
    ///
    /// **Kept rather than wiped, because the run that matters is the one that ended badly.** This
    /// was written to answer a flicker seen while the app was running, and it was wiped on launch —
    /// so a kill, a crash and a hang all destroyed exactly the evidence they were the case for. The
    /// file is one launch's section after another, newest last, with the limit trimming from the
    /// top. Idempotent because the caller is a phase change, and there are several.
    nonisolated static func begin() {
        lock.withLock {
            guard !hasBegun else { return }
            hasBegun = true
            startedAt = Date()
            lines.append("")
            lines.append("=== launch \(launches + 1) \(Date()) ===")
            launches += 1
            flushLocked()
        }
    }

    /// Writes what is in hand to disk at once, for a line that may be the last one written.
    ///
    /// Everything else here is coalesced, which is right for sixty lines a second of an animation
    /// and wrong for the last few lines before the app is killed: a quarter of a second of buffer
    /// is a quarter of a second of the answer. See ``write(_:)``.
    nonisolated static func writeNow(_ line: String) {
        write(line)
        lock.withLock { flushLocked() }
    }

    /// One rectangle, short enough to sit in a line.
    nonisolated static func short(_ rect: CGRect?) -> String {
        guard let rect else { return "none" }
        return String(
            format: "%.3f,%.3f %.3fx%.3f",
            rect.origin.x, rect.origin.y, rect.size.width, rect.size.height
        )
    }

    /// One size, short enough to sit in a line.
    nonisolated static func short(_ size: CGSize?) -> String {
        guard let size else { return "none" }
        return String(format: "%.0fx%.0f", size.width, size.height)
    }
}
