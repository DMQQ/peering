import Foundation

/// Recognises the marker a Mac-hosted terminal's shell hook emits when a command that ran a while
/// returns control to the prompt. See ``TerminalSessionManager``'s hook injection for where the
/// marker is written: an OSC sequence private to this app, in a range no real terminal convention
/// uses, that a real terminal (and this app's own ``TerminalScreen``/``TerminalTextSanitizer``)
/// already swallows as an unrecognised operating system command without rendering anything.
public struct TerminalCommandFinishDetector: Sendable {
    private static let maximumTailBytes = 4_096
    private static let marker = "\u{1B}]9999;"

    private var tail = Data()

    public init() {}

    public struct Finish: Equatable, Sendable {
        public let command: String?
        public let duration: TimeInterval
        public let exitStatus: Int32

        public init(command: String?, duration: TimeInterval, exitStatus: Int32) {
            self.command = command
            self.duration = duration
            self.exitStatus = exitStatus
        }
    }

    /// Consumes one piece of PTY output and returns a decoded marker, if a complete one is now in
    /// the tail. At most one per call: a shell emits at most one marker per prompt, and bytes
    /// through the marker's terminator are dropped afterward so it is never matched twice.
    public mutating func receive(_ data: Data) -> Finish? {
        guard !data.isEmpty else { return nil }

        tail.append(data)
        if tail.count > Self.maximumTailBytes {
            tail.removeFirst(tail.count - Self.maximumTailBytes)
        }

        let text = String(decoding: tail, as: UTF8.self)
        guard let markerRange = text.range(of: Self.marker) else { return nil }
        let bodyStart = markerRange.upperBound
        // BEL is what this app's own hook always sends; ESC (the two-byte ST terminator's first
        // byte) is accepted too, on the same terms the OSC-stripping regexes elsewhere in this
        // package do, since nothing about the marker format depends on which one arrives.
        guard let terminator = text[bodyStart...].firstIndex(where: { $0 == "\u{07}" || $0 == "\u{1B}" })
        else { return nil }

        let body = String(text[bodyStart..<terminator])
        let consumedBytes = text.utf8.distance(from: text.startIndex, to: text.index(after: terminator))
        tail.removeFirst(min(consumedBytes, tail.count))

        return Self.parse(body: body)
    }

    /// How a duration reads in a notification, rounded to whole seconds: shared by the host (a
    /// push body composed with no session up) and the phone (a live banner) so the two sentences
    /// never quietly drift apart.
    public static func durationSuffix(_ duration: TimeInterval) -> String {
        let totalSeconds = Int(duration.rounded())
        let minutes = totalSeconds / 60
        let seconds = totalSeconds % 60
        guard minutes > 0 else { return " after \(seconds)s" }
        let hours = minutes / 60
        let remainingMinutes = minutes % 60
        guard hours > 0 else { return " after \(minutes)m \(seconds)s" }
        return " after \(hours)h \(remainingMinutes)m"
    }

    private static func parse(body: String) -> Finish? {
        let parts = body.split(separator: ";", maxSplits: 2, omittingEmptySubsequences: false)
        guard parts.count == 3,
              let durationMS = Double(parts[0]),
              let exitStatus = Int32(parts[1])
        else { return nil }

        let command = Data(base64Encoded: String(parts[2])).flatMap { String(data: $0, encoding: .utf8) }
        return Finish(command: command, duration: durationMS / 1_000, exitStatus: exitStatus)
    }
}
