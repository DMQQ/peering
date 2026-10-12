import Foundation
import Testing
@testable import RemoteCore

@Suite("Terminal command finish detector")
struct TerminalCommandFinishDetectorTests {
    private let english = Locale(identifier: "en_US")

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
    func spokenDurationBoundaries() {
        #expect(TerminalCommandFinishDetector.spokenDuration(4.49, locale: english) == "4s")
        #expect(TerminalCommandFinishDetector.spokenDuration(4.5, locale: english) == "5s")
        #expect(TerminalCommandFinishDetector.spokenDuration(59.49, locale: english) == "59s")
        #expect(TerminalCommandFinishDetector.spokenDuration(59.5, locale: english) == "1m 0s")
        #expect(TerminalCommandFinishDetector.spokenDuration(65.5, locale: english) == "1m 6s")
        #expect(TerminalCommandFinishDetector.spokenDuration(3_599.49, locale: english) == "59m 59s")
        #expect(TerminalCommandFinishDetector.spokenDuration(3_599.5, locale: english) == "1h 0m")
        #expect(TerminalCommandFinishDetector.spokenDuration(3_665, locale: english) == "1h 1m")
    }

    @Test("the units are written the way the reader's language writes them")
    func spokenDurationFollowsTheLocale() {
        #expect(TerminalCommandFinishDetector.spokenDuration(125, locale: Locale(identifier: "ja_JP")) == "2\u{5206}5\u{79D2}")
        #expect(TerminalCommandFinishDetector.spokenDuration(125, locale: Locale(identifier: "de_DE")) == "2min 5s")
    }

    @Test("a duration that is not a sane number is dropped or clamped, never turned into an Int trap")
    func hostileDurationsAreContained() {
        for text in ["inf", "nan", "-5"] {
            var detector = TerminalCommandFinishDetector()
            #expect(detector.receive(Data("\u{1B}]9999;\(text);0;\u{07}".utf8)) == nil)
        }
        var detector = TerminalCommandFinishDetector()
        let huge = detector.receive(Data("\u{1B}]9999;1e30;0;\u{07}".utf8))
        #expect(huge?.duration == TerminalCommandFinishDetector.maximumDuration)
        #expect(TerminalCommandFinishDetector.spokenDuration(.infinity, locale: english) == TerminalCommandFinishDetector.spokenDuration(1e30, locale: english))
        #expect(TerminalCommandFinishDetector.spokenDuration(.nan, locale: english) == "0s")
        #expect(TerminalCommandFinishDetector.spokenDuration(-3, locale: english) == "0s")
    }
}
