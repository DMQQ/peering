//
//  TourTests.swift
//  MacCastKitTests
//

import XCTest
@testable import MacCastKit

/// The first-run tips: what each tour says, which of its steps a screen can show, and when it is
/// owed.
final class TourTests: XCTestCase {

    // MARK: The script

    /// Every tour has two to four steps (the owner's bound). This checks what is written, since missing controls drop steps at run time.
    func testEveryTourIsTwoToFourSteps() {
        for tour in Tour.allCases {
            XCTAssertGreaterThanOrEqual(tour.steps.count, 2, "\(tour) should have at least two steps.")
            XCTAssertLessThanOrEqual(tour.steps.count, 4, "\(tour) should have at most four steps.")
        }
    }

    /// No tour points at the same control twice.
    func testNoTourRepeatsATarget() {
        for tour in Tour.allCases {
            let targets = tour.steps.map(\.target)
            XCTAssertEqual(
                Set(targets).count,
                targets.count,
                "\(tour) points at the same control twice."
            )
        }
    }

    /// Every step has a non-empty title and body, which the compiler cannot enforce.
    func testEveryStepIsWritten() {
        for tour in Tour.allCases {
            for step in tour.steps {
                XCTAssertFalse(step.title.isEmpty, "\(tour)/\(step.target) has no title.")
                XCTAssertFalse(step.detail.isEmpty, "\(tour)/\(step.target) has no detail.")
                XCTAssertFalse(
                    step.detail.contains("\u{2014}"),
                    "\(tour)/\(step.target) uses an em dash."
                )
            }
        }
    }

    /// Tours need distinct saved flags: a shared key makes the second tour look already seen.
    func testEveryTourHasItsOwnFlag() {
        let keys = Tour.allCases.map(\.storageKey)
        XCTAssertEqual(Set(keys).count, keys.count, "Two tours are remembered under one key.")
        for key in keys {
            XCTAssertTrue(key.hasPrefix("Peering."), "\(key) is not namespaced like the rest.")
            XCTAssertFalse(key.isEmpty)
        }
    }

    /// Every target belongs to some tour; an unused target reports a frame nobody reads.
    func testNoTargetIsOrphaned() {
        let used = Set(Tour.allCases.flatMap { $0.steps.map(\.target) })
        for target in TourTarget.allCases {
            XCTAssertTrue(used.contains(target), "\(target) is in no tour.")
        }
    }

    // MARK: Which steps a screen can show

    /// A step whose control is not on screen is dropped, and the rest are kept in order.
    func testOnlyTheStepsThatAreOnScreenSurvive() {
        // The deck is put away while the file browser is up; the Connect tour's steps are on another screen.
        let run = TourRun(tour: .terminal, appearing: [.terminalInput])
        XCTAssertEqual(run?.steps.map(\.target), [.terminalInput])
        XCTAssertEqual(run?.count, 1)

        let both = TourRun(tour: .terminal, appearing: [.terminalDeck, .terminalInput])
        XCTAssertEqual(both?.steps.map(\.target), [.terminalDeck, .terminalInput])
    }

    /// A tour with none of its controls on screen does not start: the run is nil and nothing is marked, so it is retried.
    func testATourWithNothingOnScreenDoesNotStart() {
        XCTAssertNil(TourRun(tour: .servers, appearing: [.terminalInput]))
        XCTAssertNil(TourRun(tour: .screen, appearing: []))
    }

    /// Advancing walks off the end, which is the state that tells the view to write the flag.
    func testAdvancingPastTheLastStepFinishesTheRun() {
        var run = TourRun(tour: .shell, appearing: [.shellTabs, .shellOutput])
        XCTAssertEqual(run?.number, 1)
        XCTAssertEqual(run?.current?.target, .shellTabs)

        run?.advance()
        XCTAssertEqual(run?.number, 2)
        XCTAssertEqual(run?.current?.target, .shellOutput)
        XCTAssertEqual(run?.isFinished, false)

        run?.advance()
        XCTAssertNil(run?.current)
        XCTAssertEqual(run?.isFinished, true)
        XCTAssertEqual(run?.number, 2)
    }

    /// A control that goes from the screen mid-tour takes its step with it (the dock while the keyboard is up).
    func testAStepWhoseControlLeavesIsSkipped() {
        var run = TourRun(tour: .terminal, appearing: [.terminalDeck, .terminalInput])
        XCTAssertEqual(run?.current?.target, .terminalDeck)

        run?.skipMissing(appearing: [.terminalInput])
        XCTAssertEqual(
            run?.current?.target,
            .terminalInput,
            "The deck has gone, so its step is passed over rather than shown."
        )
    }

    /// Walking past a control that has gone never walks backwards: a returning step reads as the tour restarting.
    func testSkippingMissingStepsOnlyEverMovesForward() {
        var run = TourRun(tour: .shell, appearing: [.shellTabs, .shellOutput])
        run?.advance()
        XCTAssertEqual(run?.current?.target, .shellOutput)

        // Only an earlier step's control is on screen: the run ends rather than rewinding.
        run?.skipMissing(appearing: [.shellTabs])
        XCTAssertNil(run?.current)
        XCTAssertEqual(run?.isFinished, true)
    }

    // MARK: Being owed

    /// A fresh install owes all five, and reading them does not spend them (an unset key reads false).
    func testAFreshInstallOwesEveryTour() {
        let defaults = scratchDefaults()
        for tour in Tour.allCases {
            XCTAssertTrue(tour.isDue(in: defaults), "\(tour) should be owed on a fresh install.")
        }
    }

    /// Marking one tour seen leaves the others owed, and survives being asked again.
    func testMarkingOneSeenLeavesTheRestOwed() {
        let defaults = scratchDefaults()
        Tour.terminal.markSeen(in: defaults)

        XCTAssertFalse(Tour.terminal.isDue(in: defaults))
        for tour in Tour.allCases where tour != .terminal {
            XCTAssertTrue(tour.isDue(in: defaults), "\(tour) should still be owed.")
        }
    }

    /// The Settings row puts all five back, not just the current screen's, since nobody remembers where they skipped.
    func testResetPutsEveryTourBack() {
        let defaults = scratchDefaults()
        for tour in Tour.allCases { tour.markSeen(in: defaults) }
        Tour.resetAll(in: defaults)
        for tour in Tour.allCases {
            XCTAssertTrue(tour.isDue(in: defaults), "\(tour) should be owed again.")
        }
    }

    /// Whether a reported rectangle is visible: a control scrolled out of the viewport reports a valid but offscreen rectangle.
    func testOnlyControlsOnScreenCount() {
        let screen = CGRect(x: 0, y: 0, width: 390, height: 700)

        XCTAssertTrue(
            TourVisibility.isOnScreen(CGRect(x: 20, y: 100, width: 200, height: 60), in: screen)
        )
        XCTAssertTrue(
            TourVisibility.isOnScreen(CGRect(x: 20, y: -4, width: 200, height: 60), in: screen)
        )
        XCTAssertFalse(
            TourVisibility.isOnScreen(CGRect(x: 20, y: -58, width: 200, height: 60), in: screen)
        )
        XCTAssertFalse(
            TourVisibility.isOnScreen(CGRect(x: 20, y: 720, width: 200, height: 60), in: screen)
        )
        XCTAssertFalse(TourVisibility.isOnScreen(.zero, in: screen))
        XCTAssertFalse(TourVisibility.isOnScreen(.null, in: screen))
    }

    /// A control smaller than the floor is judged by its own size (dock chips are 20 points).
    func testASmallControlOnlyHasToShowItself() {
        let screen = CGRect(x: 0, y: 0, width: 390, height: 700)
        XCTAssertTrue(
            TourVisibility.isOnScreen(CGRect(x: 100, y: 300, width: 20, height: 20), in: screen)
        )
        XCTAssertFalse(
            TourVisibility.isOnScreen(CGRect(x: 100, y: -10, width: 20, height: 20), in: screen)
        )
    }

    /// A 14.3pt control fully inside the viewport intersected a few hundred-billionths short of its height; an exact comparison dropped its step.
    func testAControlMeasuredInFractionsOfAPointIsNotDropped() {
        let screen = CGRect(x: 0, y: 0, width: 402, height: 724)
        let button = CGRect(x: 338, y: 132.8, width: 46, height: 14.3)
        XCTAssertTrue(TourVisibility.isOnScreen(button, in: screen))
        XCTAssertTrue(TourVisibility.isOnScreen(button.insetBy(dx: 0, dy: 0.001), in: screen))
    }

    // MARK: Helpers

    /// A private suite, since UserDefaults.standard is the simulator's and would leak keys.
    private func scratchDefaults() -> UserDefaults {
        let name = "pl.dmq.peering.tourTests"
        let defaults = UserDefaults(suiteName: name) ?? .standard
        defaults.removePersistentDomain(forName: name)
        return defaults
    }
}
