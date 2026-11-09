import Foundation
import Testing

@testable import PeeringKit

@Suite("Session modes")
struct SessionModeTests {
    private func memory() -> SessionModeMemory {
        SessionModeMemory(defaults: UserDefaults(suiteName: UUID().uuidString) ?? .standard)
    }

    @Test("a Mac never chosen for asks")
    func asksFirst() {
        #expect(memory().decision(for: "mac", available: SessionMode.allCases) == .ask)
    }

    @Test("forgetting a Mac drops its mode and its pinned apps, and leaves other Macs alone")
    func forgetClearsModeAndFavourites() {
        let defaults = UserDefaults(suiteName: UUID().uuidString) ?? .standard
        let store = SessionModeMemory(defaults: defaults)
        store.remember(.remote, for: "mac")
        store.remember(.screen, for: "other")
        ApplicationFavourites(hostID: "mac", defaults: defaults).toggle("com.apple.Safari")
        ApplicationFavourites(hostID: "other", defaults: defaults).toggle("com.apple.Notes")
        store.forget("mac")
        #expect(store.remembered(for: "mac") == nil)
        #expect(ApplicationFavourites(hostID: "mac", defaults: defaults).bundleIdentifiers.isEmpty)
        #expect(store.remembered(for: "other") == .screen)
        #expect(ApplicationFavourites(hostID: "other", defaults: defaults).bundleIdentifiers == ["com.apple.Notes"])
    }

    @Test("the mode last chosen opens straight away")
    func opensRemembered() {
        let store = memory()
        store.remember(.remote, for: "mac")
        #expect(store.decision(for: "mac", available: SessionMode.allCases) == .open(.remote))
        #expect(store.decision(for: "other", available: SessionMode.allCases) == .ask)
    }

    @Test("asking every time overrides what was remembered")
    func askEveryTime() {
        let store = memory()
        store.remember(.screen, for: "mac")
        store.asksEveryTime = true
        #expect(store.decision(for: "mac", available: SessionMode.allCases) == .ask)
    }

    @Test("a remembered mode the Mac no longer offers asks again")
    func unavailableRemembered() {
        let store = memory()
        store.remember(.workspace, for: "mac")
        #expect(store.decision(for: "mac", available: [.screen, .remote]) == .ask)
    }

    @Test("forgetting a Mac asks again")
    func forgetting() {
        let store = memory()
        store.remember(.screen, for: "mac")
        store.forget("mac")
        #expect(store.decision(for: "mac", available: SessionMode.allCases) == .ask)
    }

    @Test("leaving the screen pauses the picture once and returning resumes only that pause")
    func picturePolicy() {
        #expect(SessionModePicture.action(entering: .remote, pausedByMode: false) == .pause)
        #expect(SessionModePicture.action(entering: .workspace, pausedByMode: true) == .none)
        #expect(SessionModePicture.action(entering: .screen, pausedByMode: true) == .resume)
        #expect(SessionModePicture.action(entering: .screen, pausedByMode: false) == .none)
    }
}

@Suite("Trackpad engine")
struct TrackpadEngineTests {
    @Test("finger travel moves the pointer from where the Mac says it is")
    func moves() {
        var engine = TrackpadEngine(sensitivity: 1)
        engine.adopt(x: 0.5, y: 0.5)
        let events = engine.move(dx: 50, dy: 0, padWidth: 100, padHeight: 100)
        #expect(events == [.move(x: 1.0, y: 0.5)])
    }

    @Test("the pointer stays on the screen")
    func clamps() {
        var engine = TrackpadEngine(sensitivity: 1)
        engine.adopt(x: 0.9, y: 0.1)
        _ = engine.move(dx: 500, dy: -500, padWidth: 100, padHeight: 100)
        #expect(engine.x == 1)
        #expect(engine.y == 0)
    }

    @Test("a tap clicks where the pointer is")
    func tap() {
        var engine = TrackpadEngine()
        engine.adopt(x: 0.25, y: 0.75)
        #expect(engine.tap() == [.move(x: 0.25, y: 0.75), .press(right: false), .release(right: false)])
        #expect(engine.twoFingerTap() == [.move(x: 0.25, y: 0.75), .press(right: true), .release(right: true)])
    }

    @Test("a drag holds the button until it ends, and ending twice releases once")
    func drag() {
        var engine = TrackpadEngine()
        #expect(engine.beginDrag().contains(.press(right: false)))
        #expect(engine.beginDrag().isEmpty)
        #expect(engine.endDrag() == [.release(right: false)])
        #expect(engine.endDrag().isEmpty)
    }

    @Test("a cancelled drag still releases the button")
    func cancelledDrag() {
        var engine = TrackpadEngine()
        _ = engine.beginDrag()
        #expect(engine.isDragging)
        #expect(engine.endDrag() == [.release(right: false)])
        #expect(!engine.isDragging)
    }

    @Test("scrolling is sent in pixels")
    func scrolls() {
        let engine = TrackpadEngine()
        #expect(engine.scroll(dx: 1, dy: -3) == [.scroll(dx: 2, dy: -6)])
    }

    @Test("a pad with no size moves nothing")
    func emptyPad() {
        var engine = TrackpadEngine()
        #expect(engine.move(dx: 10, dy: 10, padWidth: 0, padHeight: 0).isEmpty)
    }
}
