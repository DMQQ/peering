//
//  TourTests.swift
//  MacCastKitTests
//

import XCTest
@testable import MacCastKit

/// The first-run tips: what each tour says, which of its steps a screen can show, and when it is
/// owed.
///
/// **Three of the four things here are rules the app cannot check for itself.** The screens are
/// where a tour is drawn, and a screen can only ever see its own: it cannot know that the shell
/// tour and the terminal tour are both about the same *kind* of control, that no two tours share a
/// saved flag, or that a step pointing at a control nobody reports is dropped rather than drawn as
/// a ring around nothing. Those are statements about the whole set, and this is the only place the
/// whole set can be looked at.
final class TourTests: XCTestCase {

    // MARK: The script

    /// Every tour has between two and four steps.
    ///
    /// The bound is the owner's, and both ends of it are about the same thing: one step is not a
    /// tour, it is a tooltip with a flag that costs a screen its first-run state, and five steps is
    /// a person tapping Next through something they stopped reading at the third. A step whose
    /// control is missing is dropped at run time, so a tour *showing* two steps may be a tour with
    /// three written — this is about what is written.
    func testEveryTourIsTwoToFourSteps() {
        for tour in Tour.allCases {
            XCTAssertGreaterThanOrEqual(tour.steps.count, 2, "\(tour) should have at least two steps.")
            XCTAssertLessThanOrEqual(tour.steps.count, 4, "\(tour) should have at most four steps.")
        }
    }

    /// No tour points at the same control twice.
    ///
    /// A repeated target is two rings around one thing with two sentences between them, which is
    /// the one shape a coach mark cannot wear: the person reads the second sentence looking for the
    /// difference from the first, and there is none.
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

    /// Every step has words, and the two halves of them are the two halves of the sentence.
    ///
    /// Checked because a step is a value built at a distance from anything that would fail: an
    /// empty title draws a card with nothing on its first line and no compile error anywhere.
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

    /// The five tours are remembered in five places.
    ///
    /// A shared flag is a tour that never runs: the second screen to be reached finds the key
    /// already set by the first and decides its own tips have been seen. Keys are strings, so
    /// nothing but this would notice two cases answering the same one.
    func testEveryTourHasItsOwnFlag() {
        let keys = Tour.allCases.map(\.storageKey)
        XCTAssertEqual(Set(keys).count, keys.count, "Two tours are remembered under one key.")
        for key in keys {
            XCTAssertTrue(key.hasPrefix("Peering."), "\(key) is not namespaced like the rest.")
            XCTAssertFalse(key.isEmpty)
        }
    }

    /// Every target belongs to some tour.
    ///
    /// The other direction of the same rule the preference key relies on: a target with no step is
    /// a view reporting a frame nobody ever reads, and it would sit there for the rest of the app's
    /// life looking exactly like the targets that work.
    func testNoTargetIsOrphaned() {
        let used = Set(Tour.allCases.flatMap { $0.steps.map(\.target) })
        for target in TourTarget.allCases {
            XCTAssertTrue(used.contains(target), "\(target) is in no tour.")
        }
    }

    // MARK: Which steps a screen can show

    /// A step whose control is not on screen is dropped, and the rest are kept in order.
    func testOnlyTheStepsThatAreOnScreenSurvive() {
        // The shell tour's second step is the switch between the shell and the server's files,
        // which the screen draws at the end of the tab strip; the Connect tour's steps are on a
        // different screen entirely and none of them is reported here.
        let run = TourRun(tour: .terminal, appearing: [.terminalLog, .terminalInput])
        XCTAssertEqual(run?.steps.map(\.target), [.terminalLog, .terminalInput])
        XCTAssertEqual(run?.count, 2)
    }

    /// A tour with none of its controls on screen does not start at all.
    ///
    /// This is the difference between "not shown yet" and "seen": the run is `nil`, nothing is
    /// marked, and the screen tries again the next time its layout changes. A run with zero steps
    /// would have been finished the moment it started, which is a tour marked as read by somebody
    /// who never saw it.
    func testATourWithNothingOnScreenDoesNotStart() {
        XCTAssertNil(TourRun(tour: .servers, appearing: [.terminalLog]))
        XCTAssertNil(TourRun(tour: .screen, appearing: []))
    }

    /// Advancing walks off the end rather than stopping on the last step.
    ///
    /// The end is a state the view needs: it is what tells it the tour has been read, which is what
    /// writes the flag. A run that could not reach it would leave a tour owed forever.
    func testAdvancingPastTheLastStepFinishesTheRun() {
        var run = TourRun(tour: .shell, appearing: [.shellTabs, .shellMode])
        XCTAssertEqual(run?.number, 1)
        XCTAssertEqual(run?.current?.target, .shellTabs)

        run?.advance()
        XCTAssertEqual(run?.number, 2)
        XCTAssertEqual(run?.current?.target, .shellMode)
        XCTAssertEqual(run?.isFinished, false)

        run?.advance()
        XCTAssertNil(run?.current)
        XCTAssertEqual(run?.isFinished, true)
        // The count on the card is the number of steps that survived, not the number written.
        XCTAssertEqual(run?.number, 2)
    }

    /// A control that goes from the screen mid-tour takes its step with it.
    ///
    /// The case this exists for: the remote screen's dock, which is put away while the keyboard is
    /// up. A ring drawn around where the dock was a moment ago is a highlight over the picture.
    func testAStepWhoseControlLeavesIsSkipped() {
        var run = TourRun(tour: .terminal, appearing: [.terminalLog, .terminalDeck, .terminalInput])
        XCTAssertEqual(run?.current?.target, .terminalLog)

        run?.skipMissing(appearing: [.terminalLog, .terminalInput])
        XCTAssertEqual(run?.current?.target, .terminalLog, "The step on screen stays up.")

        run?.advance()
        run?.skipMissing(appearing: [.terminalLog, .terminalInput])
        XCTAssertEqual(
            run?.current?.target,
            .terminalInput,
            "The deck has gone, so its step is passed over rather than shown."
        )
    }

    /// Walking past a control that has gone never walks backwards.
    ///
    /// A step that came back would be the tour losing its place: the person has already read the
    /// step before it, and a ring moving back up the screen reads as the tour starting again.
    func testSkippingMissingStepsOnlyEverMovesForward() {
        var run = TourRun(tour: .terminal, appearing: [.terminalLog, .terminalDeck, .terminalInput])
        run?.advance()
        run?.advance()
        XCTAssertEqual(run?.current?.target, .terminalInput)

        // Only an earlier step's control is on screen now, which is the state a screen is in for
        // the frame after the thing the tour was pointing at has gone. The run ends rather than
        // rewinding to the step it has already shown.
        run?.skipMissing(appearing: [.terminalLog])
        XCTAssertNil(run?.current)
        XCTAssertEqual(run?.isFinished, true)
    }

    // MARK: Being owed

    /// A fresh install owes all five, and reading them does not spend them.
    ///
    /// The whole of the first-run behaviour, and the reason there is no default to write: a key
    /// that has never been set reads as `false`, which is "not seen".
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

    /// The Settings row puts all five back.
    ///
    /// All of them and not the one for the screen the row is on: the row is the way back to a tip
    /// that was skipped, and whoever skipped it does not remember which screen it was on.
    func testResetPutsEveryTourBack() {
        let defaults = scratchDefaults()
        for tour in Tour.allCases { tour.markSeen(in: defaults) }
        Tour.resetAll(in: defaults)
        for tour in Tour.allCases {
            XCTAssertTrue(tour.isDue(in: defaults), "\(tour) should be owed again.")
        }
    }

    /// Whether a reported rectangle is somewhere a person can see it.
    ///
    /// The second half of "skip the step rather than draw a hole in space". A control that is not
    /// drawn reports nothing; a control that is drawn but scrolled out of the viewport reports a
    /// rectangle that is perfectly valid and off the screen, and it is this function that tells the
    /// two apart.
    func testOnlyControlsOnScreenCount() {
        let screen = CGRect(x: 0, y: 0, width: 390, height: 700)

        XCTAssertTrue(
            TourVisibility.isOnScreen(CGRect(x: 20, y: 100, width: 200, height: 60), in: screen)
        )
        // Straddling the top edge, with most of itself showing.
        XCTAssertTrue(
            TourVisibility.isOnScreen(CGRect(x: 20, y: -4, width: 200, height: 60), in: screen)
        )
        // Above the fold, one line of itself left.
        XCTAssertFalse(
            TourVisibility.isOnScreen(CGRect(x: 20, y: -58, width: 200, height: 60), in: screen)
        )
        // Below the fold entirely.
        XCTAssertFalse(
            TourVisibility.isOnScreen(CGRect(x: 20, y: 720, width: 200, height: 60), in: screen)
        )
        // A view with no size yet, which is what the first layout pass of anything reports.
        XCTAssertFalse(TourVisibility.isOnScreen(.zero, in: screen))
        XCTAssertFalse(TourVisibility.isOnScreen(.null, in: screen))
    }

    /// A control smaller than the floor is judged by its own size.
    ///
    /// The dock's chips are 20 points across and a toolbar glyph less. Asking them for 44 points of
    /// themselves would drop them from a tour that has a step for them, which is the opposite of
    /// what the floor is for.
    func testASmallControlOnlyHasToShowItself() {
        let screen = CGRect(x: 0, y: 0, width: 390, height: 700)
        XCTAssertTrue(
            TourVisibility.isOnScreen(CGRect(x: 100, y: 300, width: 20, height: 20), in: screen)
        )
        // ...and it is still not on screen when it is off it.
        XCTAssertFalse(
            TourVisibility.isOnScreen(CGRect(x: 100, y: -10, width: 20, height: 20), in: screen)
        )
    }

    /// A control the size of a small one, measured in fractions of a point, is still on screen.
    ///
    /// **This is the shape the real one came in**, and it is why the rule has a slack in it. The
    /// switch between a shell and its server's files is 14.3 points tall, and when it is entirely
    /// inside the viewport the intersection comes back a few hundred-billionths short of its own
    /// height. Written as an exact comparison, the step about it was dropped on a screen where the
    /// control was perfectly visible, and nothing anywhere said so: a missing step looks exactly
    /// like a tour that has one step fewer.
    func testAControlMeasuredInFractionsOfAPointIsNotDropped() {
        let screen = CGRect(x: 0, y: 0, width: 402, height: 724)
        let button = CGRect(x: 338, y: 132.8, width: 46, height: 14.3)
        XCTAssertTrue(TourVisibility.isOnScreen(button, in: screen))
        XCTAssertTrue(TourVisibility.isOnScreen(button.insetBy(dx: 0, dy: 0.001), in: screen))
    }

    // MARK: Helpers

    /// Defaults of this test's own, wiped first.
    ///
    /// A suite rather than `UserDefaults.standard`, which on this machine is the simulator's and
    /// would leave five keys set for whatever runs next.
    private func scratchDefaults() -> UserDefaults {
        let name = "pl.dmq.peering.tourTests"
        let defaults = UserDefaults(suiteName: name) ?? .standard
        defaults.removePersistentDomain(forName: name)
        return defaults
    }
}
