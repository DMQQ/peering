import Foundation
import Testing

@testable import RemoteCore

struct MacroTests {
    private func point(_ x: Double, _ y: Double) -> RemoteCommand { .mouseMove(to: NormalizedPoint(x: x, y: y)) }

    @Test func theFirstStepStartsAtOnceAndLaterOnesKeepTheirGap() {
        var recorder = MacroRecorder()
        recorder.record(.mouseDown(button: .left), at: 10)
        recorder.record(.mouseUp(button: .left), at: 10.25)
        #expect(recorder.steps.map(\.delayMilliseconds) == [0, 250])
    }

    @Test func pointerMovesInsideTheMergeWindowBecomeOneMove() {
        var recorder = MacroRecorder()
        recorder.record(point(0.1, 0.1), at: 1.000)
        recorder.record(point(0.2, 0.2), at: 1.010)
        recorder.record(point(0.3, 0.3), at: 1.020)
        #expect(recorder.steps.count == 1)
        #expect(recorder.steps[0].command == point(0.3, 0.3))
    }

    @Test func pointerMovesFurtherApartAreKept() {
        var recorder = MacroRecorder()
        recorder.record(point(0.1, 0.1), at: 1.0)
        recorder.record(point(0.2, 0.2), at: 1.2)
        #expect(recorder.steps.count == 2)
    }

    @Test func aCommandAMacroCannotHoldIsIgnoredAndLeavesNoGap() {
        var recorder = MacroRecorder()
        recorder.record(.keyDown(keyCode: 0, modifiers: []), at: 1)
        recorder.record(.pushClipboard(text: "secret"), at: 2)
        recorder.record(.lockScreen, at: 3)
        recorder.record(.keyUp(keyCode: 0, modifiers: []), at: 4)
        #expect(recorder.steps.count == 2)
        #expect(recorder.steps[1].delayMilliseconds == 3_000)
    }

    @Test func aLongPauseIsStoredAtTheCap() {
        var recorder = MacroRecorder()
        recorder.record(.keyDown(keyCode: 0, modifiers: []), at: 0)
        recorder.record(.keyUp(keyCode: 0, modifiers: []), at: 120)
        #expect(recorder.steps[1].delayMilliseconds == MacroLimits.maxStepDelayMilliseconds)
    }

    @Test func recordingStopsAtTheStepLimit() {
        var recorder = MacroRecorder()
        for index in 0..<(MacroLimits.maxSteps + 5) {
            recorder.record(.mouseDown(button: .left), at: Double(index) * 0.001)
        }
        #expect(recorder.steps.count == MacroLimits.maxSteps)
        #expect(recorder.stopped == .stepLimit)
    }

    @Test func recordingStopsAtTheDurationLimit() {
        var recorder = MacroRecorder()
        for index in 0..<100 {
            recorder.record(.mouseDown(button: .left), at: Double(index) * 5)
        }
        #expect(recorder.stopped == .durationLimit)
        #expect(recorder.macro(named: "x").duration <= MacroLimits.maxDurationSeconds)
    }

    @Test func aTextStepLongerThanTheLimitIsRefused() {
        let long = String(repeating: "a", count: MacroLimits.maxTextCharacters + 1)
        #expect(!MacroLimits.accepts(.textInput(long)))
        #expect(MacroLimits.accepts(.textInput("hello")))
    }

    @Test func aRecordedMacroPassesTheLimits() {
        var recorder = MacroRecorder()
        recorder.record(.launchApplication(bundleIdentifier: "com.apple.TextEdit"), at: 0)
        recorder.record(.textInput("hi"), at: 1)
        #expect(MacroLimits.problem(with: recorder.macro(named: "Note")) == nil)
    }

    @Test func aMacroWithNoStepsOrNoNameOrAForbiddenCommandIsRejected() {
        #expect(MacroLimits.problem(with: Macro(name: "Empty", steps: [])) != nil)
        let step = MacroStep(delayMilliseconds: 0, command: .keyDown(keyCode: 0, modifiers: []))
        #expect(MacroLimits.problem(with: Macro(name: "  ", steps: [step])) != nil)
        let forbidden = MacroStep(delayMilliseconds: 0, command: .setPrivacyMode(enabled: true))
        #expect(MacroLimits.problem(with: Macro(name: "Bad", steps: [forbidden])) != nil)
        let slow = MacroStep(delayMilliseconds: MacroLimits.maxStepDelayMilliseconds + 1, command: step.command)
        #expect(MacroLimits.problem(with: Macro(name: "Slow", steps: [slow])) != nil)
    }

    @Test func aMacroSurvivesAJSONRoundTrip() throws {
        var recorder = MacroRecorder()
        recorder.record(point(0.5, 0.5), at: 0)
        recorder.record(.scroll(dx: 0, dy: -3), at: 0.5)
        let macro = Macro(name: "Scroll", steps: recorder.steps, schedule: .daily(hour: 9, minute: 30, weekdays: [2, 3]))
        let decoded = try JSONDecoder().decode(Macro.self, from: JSONEncoder().encode(macro))
        #expect(decoded == macro)
    }
}
