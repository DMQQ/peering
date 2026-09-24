import Foundation
import Testing
@testable import RemoteCore

@Suite("Terminal command finish detector")
struct TerminalCommandFinishDetectorTests {
    private static func marker(durationMS: Int, exitStatus: Int32, command: String) -> Data {
        let encodedCommand = Data(command.utf8).base64EncodedString()
        let text = "\u{1B}]9999;\(durationMS);\(exitStatus);\(encodedCommand)\u{07}"
        return Data(text.utf8)
    }

    @Test("a complete marker decodes command, duration and exit status")
    func decodesCompleteMarker() {
        var detector = TerminalCommandFinishDetector()
        let data = Self.marker(durationMS: 5_500, exitStatus: 0, command: "npm run build")

        let finish = detector.receive(data)

        #expect(finish?.command == "npm run build")
        #expect(finish?.duration == 5.5)
        #expect(finish?.exitStatus == 0)
    }

    @Test("prompt text around the marker does not interfere")
    func decodesMarkerAmongOrdinaryOutput() {
        var detector = TerminalCommandFinishDetector()
        var data = Data("Build succeeded\r\n".utf8)
        data.append(Self.marker(durationMS: 12_340, exitStatus: 1, command: "make test"))
        data.append(Data("$ ".utf8))

        let finish = detector.receive(data)

        #expect(finish?.command == "make test")
        #expect(finish?.exitStatus == 1)
    }

    @Test("a marker split across reads is detected only once complete")
    func detectsSplitMarker() {
        var detector = TerminalCommandFinishDetector()
        let whole = Self.marker(durationMS: 8_000, exitStatus: 0, command: "sleep 8")
        let splitPoint = whole.count / 2
        let first = whole.prefix(splitPoint)
        let second = whole.suffix(from: splitPoint)

        #expect(detector.receive(Data(first)) == nil)
        #expect(detector.receive(Data(second))?.command == "sleep 8")
    }

    @Test("the same marker is never reported twice")
    func doesNotRepeatAMarker() {
        var detector = TerminalCommandFinishDetector()
        let data = Self.marker(durationMS: 5_000, exitStatus: 0, command: "sleep 5")

        #expect(detector.receive(data) != nil)
        #expect(detector.receive(Data()) == nil)
    }

    @Test("a malformed marker is ignored rather than crashing")
    func ignoresMalformedMarker() {
        var detector = TerminalCommandFinishDetector()
        let malformed = Data("\u{1B}]9999;not-a-number;0;not-base64\u{07}".utf8)

        #expect(detector.receive(malformed) == nil)
    }

    @Test("no command survives when the payload cannot be decoded")
    func fallsBackToNoCommand() {
        var detector = TerminalCommandFinishDetector()
        let text = "\u{1B}]9999;5000;2;not-valid-base64!!!\u{07}"

        #expect(detector.receive(Data(text.utf8))?.command == nil)
    }

    @Test("notification durations round at the seconds, minutes and hours boundaries")
    func durationSuffixBoundaries() {
        #expect(TerminalCommandFinishDetector.durationSuffix(4.49) == " after 4s")
        #expect(TerminalCommandFinishDetector.durationSuffix(4.5) == " after 5s")
        #expect(TerminalCommandFinishDetector.durationSuffix(59.49) == " after 59s")
        #expect(TerminalCommandFinishDetector.durationSuffix(59.5) == " after 1m 0s")
        #expect(TerminalCommandFinishDetector.durationSuffix(65.5) == " after 1m 6s")
        #expect(TerminalCommandFinishDetector.durationSuffix(3_599.49) == " after 59m 59s")
        #expect(TerminalCommandFinishDetector.durationSuffix(3_599.5) == " after 1h 0m")
        #expect(TerminalCommandFinishDetector.durationSuffix(3_665) == " after 1h 1m")
    }
}
