import Foundation

/// Recognises the marker a Mac-hosted terminal's shell hook emits when a long command returns to the prompt: an OSC sequence private to this app (see ``TerminalSessionManager``'s hook injection), which real terminals swallow as unrecognised.
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

    /// At most one marker per call; bytes through its terminator are dropped so it is never matched twice.
    public mutating func receive(_ data: Data) -> Finish? {
        guard !data.isEmpty else { return nil }

        tail.append(data)
        if tail.count > Self.maximumTailBytes {
            tail.removeFirst(tail.count - Self.maximumTailBytes)
        }

        let text = String(decoding: tail, as: UTF8.self)
        guard let markerRange = text.range(of: Self.marker) else { return nil }
        let bodyStart = markerRange.upperBound
        // BEL is what the hook sends; ESC (start of ST) is accepted as the OSC-stripping regexes do.
        guard let terminator = text[bodyStart...].firstIndex(where: { $0 == "\u{07}" || $0 == "\u{1B}" })
        else { return nil }

        let body = String(text[bodyStart..<terminator])
        let consumedBytes = text.utf8.distance(from: text.startIndex, to: text.index(after: terminator))
        tail.removeFirst(min(consumedBytes, tail.count))

        return Self.parse(body: body)
    }

    /// Anything longer reads the same: a marker is printed by whatever runs in the terminal, so the number is not to be trusted.
    static let maximumDuration: TimeInterval = 30 * 24 * 3_600

    /// "4s", "2m 5s" or "3h 5m" in the reader's language. Shared by host (push body) and phone (live banner) so the two sentences cannot drift.
    public static func spokenDuration(_ duration: TimeInterval, locale: Locale = .current) -> String {
        let bounded = duration.isNaN ? 0 : min(max(duration, 0), maximumDuration)
        let totalSeconds = Int(bounded.rounded())
        let minutes = totalSeconds / 60
        let allowed: Set<Duration.UnitsFormatStyle.Unit>
        let shown: Int
        if minutes == 0 {
            allowed = [.seconds]
            shown = totalSeconds
        } else if minutes < 60 {
            allowed = [.minutes, .seconds]
            shown = totalSeconds
        } else {
            allowed = [.hours, .minutes]
            shown = minutes * 60
        }
        let style = Duration.UnitsFormatStyle.units(allowed: allowed, width: .narrow, zeroValueUnits: .show(length: 1))
        return Duration.seconds(shown).formatted(style.locale(locale))
    }

    /// Reads back the English form `spokenDuration` writes ("4s", "2m 5s", "3h 5m"), or `nil` for anything else, such as a Mac set to another language.
    public static func seconds(fromEnglishSpokenDuration text: String) -> TimeInterval? {
        let units: [Character: Int] = ["h": 3_600, "m": 60, "s": 1]
        let parts = text.split(whereSeparator: { $0.isWhitespace })
        guard (1...3).contains(parts.count) else { return nil }
        var total = 0
        var previousUnit = Int.max
        for part in parts {
            let digits = part.dropLast()
            guard let letter = part.last, let unit = units[letter], unit < previousUnit,
                  !digits.isEmpty, digits.allSatisfy({ $0.isASCII && $0.isNumber }), let value = Int(digits)
            else { return nil }
            total += value * unit
            previousUnit = unit
        }
        return TimeInterval(total)
    }

    private static func parse(body: String) -> Finish? {
        let parts = body.split(separator: ";", maxSplits: 2, omittingEmptySubsequences: false)
        guard parts.count == 3,
              let durationMS = Double(parts[0]), durationMS.isFinite, durationMS >= 0,
              let exitStatus = Int32(parts[1])
        else { return nil }

        let command = Data(base64Encoded: String(parts[2])).flatMap { String(data: $0, encoding: .utf8) }
        return Finish(command: command, duration: min(durationMS / 1_000, maximumDuration), exitStatus: exitStatus)
    }
}
