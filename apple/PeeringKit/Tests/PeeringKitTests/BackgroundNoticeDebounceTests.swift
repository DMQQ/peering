import Foundation
import Testing

@testable import PeeringKit

@Suite("Background notice debounce")
struct BackgroundNoticeDebounceTests {
    private let t0 = ContinuousClock.Instant.now

    @Test("an inactive that ends within the delay tells the Mac nothing")
    func briefInactiveIsSilent() {
        var debounce = BackgroundNoticeDebounce()
        #expect(debounce.becameInactive(now: t0) == .wait(until: (t0 + .seconds(1))))
        #expect(debounce.becameActive() == .tell(background: false))
        #expect(debounce.fire(now: (t0 + .seconds(1))) == .none)
    }

    @Test("an inactive that lasts past the delay tells the Mac the app left")
    func longInactiveTells() {
        var debounce = BackgroundNoticeDebounce()
        _ = debounce.becameInactive(now: t0)
        #expect(debounce.fire(now: (t0 + .seconds(0.5))) == .none)
        #expect(debounce.fire(now: (t0 + .seconds(1))) == .tell(background: true))
        #expect(debounce.fire(now: (t0 + .seconds(2))) == .none)
    }

    @Test("background tells the Mac at once and cancels the wait")
    func backgroundIsImmediate() {
        var debounce = BackgroundNoticeDebounce()
        _ = debounce.becameInactive(now: t0)
        #expect(debounce.becameBackground() == .tell(background: true))
        #expect(debounce.fire(now: (t0 + .seconds(5))) == .none)
    }

    @Test("a second inactive does not push the deadline out")
    func deadlineStaysPut() {
        var debounce = BackgroundNoticeDebounce()
        _ = debounce.becameInactive(now: t0)
        #expect(debounce.becameInactive(now: (t0 + .seconds(0.8))) == .wait(until: (t0 + .seconds(1))))
    }
}
