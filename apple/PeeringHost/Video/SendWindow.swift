import Foundation

/// What the send path did over the last few seconds, so a stutter can be told apart: a slow send shows as long sends and drops, a slow capture or encoder as few frames arriving at all.
struct SendWindow {
    private static let length: TimeInterval = 5

    private var startedAt: TimeInterval?
    private var arrived = 0
    private var sent = 0
    private var dropped = 0
    private var sendSeconds: TimeInterval = 0
    private var slowestSend: TimeInterval = 0

    mutating func noteArrival() { arrived += 1 }
    mutating func noteDrop() { dropped += 1 }

    /// A send finished. Returns the summary once the window is full, and starts the next.
    mutating func noteSent(tookSeconds: TimeInterval, at now: TimeInterval) -> String? {
        let start = startedAt ?? now
        startedAt = start
        sent += 1
        sendSeconds += tookSeconds
        slowestSend = max(slowestSend, tookSeconds)
        let elapsed = now - start
        guard elapsed >= Self.length else { return nil }
        let summary = String(
            format: "send path · %.0f frames/s in, %.0f/s out, %d dropped · send avg %.1f ms, slowest %.0f ms",
            Double(arrived) / elapsed, Double(sent) / elapsed, dropped,
            sendSeconds / Double(sent) * 1000, slowestSend * 1000
        )
        self = SendWindow()
        startedAt = now
        return summary
    }
}
