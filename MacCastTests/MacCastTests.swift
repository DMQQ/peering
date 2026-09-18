//
//  MacCastTests.swift
//  MacCastTests
//
//  Created by Damian Derlecki on 13/09/2026.
//

import RemoteCore
import AVFoundation
import XCTest
@testable import MacCast

final class MacCastTests: XCTestCase {

    func testAutoQualityStartsConservativelyForTheConnectionPath() {
        XCTAssertEqual(AutoQualityPolicy(path: .lan).tier, .high)
        XCTAssertEqual(AutoQualityPolicy(path: .direct).tier, .high)
        XCTAssertEqual(AutoQualityPolicy(path: .relay).tier, .medium)
    }

    func testAutoQualityDropsImmediatelyWhenLatencyOrDropsRise() {
        var policy = AutoQualityPolicy(path: .lan)

        XCTAssertEqual(policy.observe(latencyMilliseconds: 190, newDroppedFrames: 0), .medium)
        XCTAssertEqual(policy.observe(latencyMilliseconds: 40, newDroppedFrames: 1), .low)
    }

    func testAutoQualityNeedsSustainedHealthBeforeRaisingBitrate() {
        var policy = AutoQualityPolicy(path: .relay)

        for _ in 0..<(AutoQualityPolicy.healthySamplesForUpgrade - 1) {
            XCTAssertNil(policy.observe(latencyMilliseconds: 55, newDroppedFrames: 0))
        }
        XCTAssertEqual(policy.observe(latencyMilliseconds: 55, newDroppedFrames: 0), .high)
    }

    func testAutoQualityDoesNotRaiseRelayQualityOnMediocreLatency() {
        var policy = AutoQualityPolicy(path: .relay)

        for _ in 0..<(AutoQualityPolicy.healthySamplesForUpgrade * 2) {
            XCTAssertNil(policy.observe(latencyMilliseconds: 110, newDroppedFrames: 0))
        }
        XCTAssertEqual(policy.tier, .medium)
    }

    func testManualQualityOffersEveryPresetButAutomatic() {
        // What the settings panel draws under "Manual". `auto` belongs to the mode picker above
        // it, and a preset that appeared in both lists would be two controls for one setting.
        XCTAssertEqual(SessionModel.StreamQuality.manualCases, [.low, .medium, .high])
    }

    func testTakingTheRateOverByHandStartsWhereAutomaticHadIt() {
        // ``SessionModel/setAutomaticQuality(_:)`` hands the policy's current tier to the manual
        // picker on the first switch. That is only seamless if a tier and the preset naming it
        // agree on the rate — they are two separate enums that share a number, and the compiler
        // does not connect them, so this is what holds them together.
        for tier in [AutoQualityPolicy.Tier.low, .medium, .high] {
            let preset = SessionModel.StreamQuality(tier)
            XCTAssertEqual(preset.bitrateKbps, tier.bitrateKbps)
        }
    }

    func testEveryQualityPresetSurvivesBeingStoredAndReadBack() {
        // The stored preference is a `rawValue` in `UserDefaults`, so a preset that did not
        // round-trip would come back as something else on the next launch — and the failure is
        // silent, because `storedQuality` decodes a token it cannot read as "nothing stored".
        for preset in SessionModel.StreamQuality.allCases {
            XCTAssertEqual(SessionModel.StreamQuality(rawValue: preset.rawValue), preset)
        }
    }

    func testTheWordsOnTheChipAreNotWhatIsStored() {
        // ``StreamQuality/chipTitle`` is deliberately not the raw value, and this is the test
        // that says so out loud. The raw value used to be the printed word, "Med" included, and
        // an abbreviation chosen for a chip that shares a row with four other controls is not
        // something a saved preference should be keyed on: the day it is reconsidered, every
        // stored value stops decoding and resets to automatic without saying anything.
        //
        // Decoding the old spellings to `nil` is the fix, not a regression — nothing has ever
        // written them under this key.
        for preset in SessionModel.StreamQuality.allCases {
            XCTAssertNil(SessionModel.StreamQuality(rawValue: preset.chipTitle))
        }
        XCTAssertNil(SessionModel.StreamQuality(rawValue: "Med"))
        XCTAssertNil(SessionModel.StreamQuality(rawValue: ""))
    }

    func testTheChipStillSpellsTheFourWordsItAlwaysDid() {
        // The rename of `rawValue` to `chipTitle` is invisible on screen or it is a bug: these
        // are the four strings the speed chip printed before it, and it prints them still.
        XCTAssertEqual(SessionModel.StreamQuality.auto.chipTitle, "Auto")
        XCTAssertEqual(SessionModel.StreamQuality.low.chipTitle, "Low")
        XCTAssertEqual(SessionModel.StreamQuality.medium.chipTitle, "Med")
        XCTAssertEqual(SessionModel.StreamQuality.high.chipTitle, "High")
    }

    func testTheQualityMenuNamesTheRateItIsOffering() {
        // The whole reason the menu exists in two places rather than one: "Low" names a rung on
        // a ladder nobody has been shown, so every option carries what it costs. Both the speed
        // chip and the Settings tab read this, which is what stops them describing the same four
        // presets differently.
        for preset in SessionModel.StreamQuality.allCases {
            XCTAssertTrue(
                preset.menuTitle.contains(preset.title),
                "\(preset.menuTitle) does not name \(preset.title)"
            )
        }
        XCTAssertEqual(SessionModel.StreamQuality.low.menuTitle, "Low, 2 Mbps")
        XCTAssertEqual(SessionModel.StreamQuality.high.menuTitle, "High, 20 Mbps")
    }

    @MainActor
    func testAnUnrecognisedQualityFallsBackToAutomatic() {
        // ``SessionModel/storedQuality`` is the read side of the preference, and it has to answer
        // for a key that was never written — which is every install that predates the setting,
        // and the state of this one right now. Automatic is the behaviour the app had before the
        // setting existed, so it is the only honest default. Removed again so the test leaves no
        // preference behind for the next run.
        let key = PreferenceKey.streamQuality
        let previous = UserDefaults.standard.object(forKey: key)
        defer {
            if let previous {
                UserDefaults.standard.set(previous, forKey: key)
            } else {
                UserDefaults.standard.removeObject(forKey: key)
            }
        }

        UserDefaults.standard.removeObject(forKey: key)
        XCTAssertEqual(SessionModel.storedQuality, .auto)

        UserDefaults.standard.set("ultra", forKey: key)
        XCTAssertEqual(SessionModel.storedQuality, .auto)

        UserDefaults.standard.set(SessionModel.StreamQuality.medium.rawValue, forKey: key)
        XCTAssertEqual(SessionModel.storedQuality, .medium)
    }

    @MainActor
    func testASessionStartsAtWhatTheSettingsTabStored() {
        // The half of the feature that is easy to leave out, and was. The Settings tab writes the
        // preference and cannot reach the model — the model is built once for the life of the
        // process, and that tab is unreachable while a session runs, which is why it writes a
        // preference at all. So its copy of the preset is stale from launch, and the arrival is
        // the only moment the two can be brought back together. Read the property instead of the
        // token in ``SessionModel/applyInitialQuality()`` and this passes only when the change
        // happened to be made before the app was started, which no test run would notice.
        let key = PreferenceKey.streamQuality
        let previous = UserDefaults.standard.object(forKey: key)
        defer {
            if let previous {
                UserDefaults.standard.set(previous, forKey: key)
            } else {
                UserDefaults.standard.removeObject(forKey: key)
            }
        }

        UserDefaults.standard.set(SessionModel.StreamQuality.high.rawValue, forKey: key)
        // Built *after* the write, and the point is that the write is still what decides: the
        // model is seeded at init, so a value stored while one is already running is the case
        // that went wrong and the one worth asserting on.
        let model = SessionModel()
        model.applyInitialQuality()

        XCTAssertEqual(model.streamQuality, .high)
        XCTAssertEqual(model.lastManualQuality, .high)
        XCTAssertEqual(
            UserDefaults.standard.string(forKey: key),
            "high",
            "Adopting must not write the preference back — the Settings row observes that key."
        )

        // And the automatic case, which must come back automatic and must not invent a manual
        // level to return to: there is none, and the policy's tier is what stands in.
        UserDefaults.standard.set(SessionModel.StreamQuality.auto.rawValue, forKey: key)
        let automatic = SessionModel()
        automatic.applyInitialQuality()

        XCTAssertEqual(automatic.streamQuality, .auto)
        XCTAssertNil(automatic.lastManualQuality)
    }

    func testDeltaVideoSampleIsMarkedAsDependentAndNotSync() throws {
        let sample = try makeVideoSample(isKeyframe: false)

        XCTAssertEqual(attachmentBool(sample, kCMSampleAttachmentKey_NotSync), true)
        XCTAssertEqual(attachmentBool(sample, kCMSampleAttachmentKey_DependsOnOthers), true)
        XCTAssertEqual(attachmentBool(sample, kCMSampleAttachmentKey_DisplayImmediately), true)
    }

    func testKeyframeVideoSampleIsMarkedAsIndependentAndSync() throws {
        let sample = try makeVideoSample(isKeyframe: true)

        XCTAssertEqual(attachmentBool(sample, kCMSampleAttachmentKey_NotSync), false)
        XCTAssertEqual(attachmentBool(sample, kCMSampleAttachmentKey_DependsOnOthers), false)
        XCTAssertEqual(attachmentBool(sample, kCMSampleAttachmentKey_DisplayImmediately), true)
    }

    private func makeVideoSample(isKeyframe: Bool) throws -> CMSampleBuffer {
        var format: CMVideoFormatDescription?
        XCTAssertEqual(CMVideoFormatDescriptionCreate(
            allocator: kCFAllocatorDefault,
            codecType: kCMVideoCodecType_H264,
            width: 16,
            height: 16,
            extensions: nil,
            formatDescriptionOut: &format
        ), noErr)
        let frame = EncodedVideoFrame(
            isKeyframe: isKeyframe,
            pixelWidth: 16,
            pixelHeight: 16,
            presentationTime: VideoTimestamp(value: 0, timescale: 600),
            data: Data([0, 0, 0, 1])
        )
        return try XCTUnwrap(VideoRenderer.makeSampleBuffer(frame, format: try XCTUnwrap(format)))
    }

    private func attachmentBool(_ sample: CMSampleBuffer, _ key: CFString) -> Bool? {
        CMGetAttachment(sample, key: key, attachmentModeOut: nil)
            .map { CFBooleanGetValue($0 as! CFBoolean) }
    }

    // Gesture locations and the bounds used to normalize them must come from the same UIKit
    // view. RemoteScreen used to mix this full-screen coordinate space with its safe-area-sized
    // SwiftUI root, shifting the Mac cursor much farther in portrait than in landscape.
    @MainActor
    func testPortraitGestureSurfaceUsesItsOwnBoundsForCentreTap() async throws {
        let normalized = try await normalizedCentreReportedByGestureSurface(
            size: CGSize(width: 430, height: 932)
        )

        XCTAssertEqual(normalized.x, 0.5, accuracy: 0.001)
        XCTAssertEqual(normalized.y, 0.5, accuracy: 0.001)
    }

    @MainActor
    func testLandscapeGestureSurfaceUsesItsOwnBoundsForCentreTap() async throws {
        let normalized = try await normalizedCentreReportedByGestureSurface(
            size: CGSize(width: 932, height: 430)
        )

        XCTAssertEqual(normalized.x, 0.5, accuracy: 0.001)
        XCTAssertEqual(normalized.y, 0.5, accuracy: 0.001)
    }

    func testClientCursorUsesTheInverseOfTouchMapping() throws {
        let bounds = CGSize(width: 932, height: 430)
        let pixels = CGSize(width: 1512, height: 982)
        let original = CGPoint(x: 713, y: 118)
        let normalized = try XCTUnwrap(CanvasGeometry.normalized(
            point: original,
            bounds: bounds,
            pixelSize: pixels,
            zoom: 1.7,
            pan: CGSize(width: -41, height: 23)
        ))
        let reconstructed = try XCTUnwrap(CanvasGeometry.point(
            normalized: normalized,
            bounds: bounds,
            pixelSize: pixels,
            zoom: 1.7,
            pan: CGSize(width: -41, height: 23)
        ))

        XCTAssertEqual(reconstructed.x, original.x, accuracy: 0.001)
        XCTAssertEqual(reconstructed.y, original.y, accuracy: 0.001)
    }

    // MARK: - Interaction mode

    // Control combines Mac input with picture navigation. Observe is the safety boundary: no
    // input reaches the Mac.

    func testViewAndScrollTouchesReachTheMac() {
        let mode = InteractionMode.control

        XCTAssertFalse(mode.oneFingerDragPansCanvas)
        XCTAssertTrue(mode.tapsReachTheMac)
    }

    /// Looking closer is not a mode.
    ///
    /// The pinch used to be drag & zoom's alone, because a zoom silently rescaled the canvas and
    /// every click after it was mapped through that scale. `CanvasGeometry.normalized` undoes
    /// both the zoom and the pan now, so the pinch is free in both modes — and what the mode
    /// decides is only whether a *drag* pans, which it does once the picture overflows its view
    /// and there is somewhere to pan to.
    func testViewAndScrollZoomsAlwaysButPansOnlyWhenOverflowing() {
        let mode = InteractionMode.control

        XCTAssertTrue(mode.pinchZoomsCanvas)
        XCTAssertFalse(mode.twoFingerDragPansCanvas(isZoomed: false))
        XCTAssertTrue(mode.twoFingerDragPansCanvas(isZoomed: true))
    }

    func testObserveModeCanInspectThePictureWithoutInput() {
        let mode = InteractionMode.observe

        XCTAssertTrue(mode.oneFingerDragPansCanvas)
        XCTAssertFalse(mode.oneFingerDragReachesTheMac)
        XCTAssertTrue(mode.twoFingerDragPansCanvas(isZoomed: false))
        XCTAssertTrue(mode.pinchZoomsCanvas)
        XCTAssertFalse(mode.tapsReachTheMac)
    }

    // MARK: - Putting a panel away

    // A panel is modal in intent but not in shape: it covers a corner of the picture and the rest
    // of the screen is still the Mac. These pin which taps put it away, for the same reason the
    // routing above is pinned rather than driven through a recogniser.

    private var panelRegion: CGRect { CGRect(x: 0, y: 700, width: 520, height: 120) }

    func testTapOnThePictureDismissesAnOpenPanel() {
        XCTAssertTrue(CanvasGeometry.dismissesOverlay(
            at: CGPoint(x: 200, y: 300),
            regions: [panelRegion],
            isOpen: true
        ))
    }

    func testTapOnThePanelItselfDoesNotDismissIt() {
        // The panel's own tiles and buttons are inside this rect, and a tap on one belongs to the
        // control under it. Dismissing here would close the panel out from under the user's aim.
        XCTAssertFalse(CanvasGeometry.dismissesOverlay(
            at: CGPoint(x: 200, y: 750),
            regions: [panelRegion],
            isOpen: true
        ))
    }

    func testTapOnThePictureIsAnOrdinaryClickWhileNoPanelIsOpen() {
        XCTAssertFalse(CanvasGeometry.dismissesOverlay(
            at: CGPoint(x: 200, y: 300),
            regions: [],
            isOpen: false
        ))
    }

    /// A drag either moves the picture or is sent to the Mac, never both. Stated as an invariant
    /// over every case so a mode added later cannot quietly be both at once — and the failure
    /// that would produce is not subtle: a picture sliding under the finger while a window moves
    /// on the Mac, from one gesture.
    func testNoModeBothMovesThePictureAndReachesTheMacOnOneDrag() {
        for mode in InteractionMode.allCases {
            XCTAssertFalse(mode.oneFingerDragPansCanvas && mode.oneFingerDragReachesTheMac)
        }
    }

    func testInteractionModeButtonCyclesThroughEveryMode() {
        for mode in InteractionMode.allCases {
            XCTAssertEqual(mode.toggled.toggled, mode)
        }
        XCTAssertEqual(InteractionMode.allCases.count, 2)
    }

    /// The switch is stored as its raw value, so that string is a persistence format and not an
    /// implementation detail. The default has to be the behaviour that existed before the switch
    /// did, or an upgrade silently changes how the screen responds to a finger.
    func testInteractionModeRoundTripsThroughItsStoredValue() {
        for mode in InteractionMode.allCases {
            XCTAssertEqual(InteractionMode(rawValue: mode.rawValue), mode)
        }

        XCTAssertEqual(InteractionMode(rawValue: "control"), .control)
        XCTAssertEqual(InteractionMode(rawValue: "navigate"), .control)
        XCTAssertNil(InteractionMode(rawValue: "dragging"))
    }

    /// The rail button is captioned with the mode's own name and icon, so two modes that agreed
    /// on either would leave a button that cannot say which way it is pointing.
    func testEachModeIsDistinguishableOnItsButton() {
        XCTAssertEqual(Set(InteractionMode.allCases.map(\.label)).count, InteractionMode.allCases.count)
        XCTAssertEqual(Set(InteractionMode.allCases.map(\.symbol)).count, InteractionMode.allCases.count)
    }

    /// UIKit may end the pinch recognizer before its simultaneous pan recognizer. Translation
    /// accumulated while the pinch owned both fingers must already be gone when that happens,
    /// or the pan recognizer delivers the whole pinch movement as one jump on release.
    func testTwoFingerPanDoesNotReplayPinchMovementWhenPinchEndsFirst() {
        var recognizerTranslation = CGPoint(x: 74, y: -31)

        let duringPinch = CanvasGestureRouting.twoFingerPan(
            translation: recognizerTranslation,
            whilePinching: true
        )
        if duringPinch.resetsRecognizerTranslation {
            recognizerTranslation = .zero
        }

        let afterPinchEnded = CanvasGestureRouting.twoFingerPan(
            translation: recognizerTranslation,
            whilePinching: false
        )

        XCTAssertNil(afterPinchEnded.translation)
    }

    func testPinchReleaseDoesNotApplyAStaleFinalScale() {
        XCTAssertNil(CanvasGestureRouting.pinchScale(for: .ended, scale: 1.24))
        XCTAssertNil(CanvasGestureRouting.pinchScale(for: .cancelled, scale: 0.86))
        XCTAssertEqual(CanvasGestureRouting.pinchScale(for: .changed, scale: 1.24), 1.24)
    }

    func testTwoFingerPanSuppressesLiftOffAfterPinch() {
        XCTAssertFalse(CanvasGestureRouting.shouldDeliverTwoFingerPan(
            whilePinching: false,
            suppressingAfterPinch: true
        ))
        XCTAssertTrue(CanvasGestureRouting.shouldDeliverTwoFingerPan(
            whilePinching: false,
            suppressingAfterPinch: false
        ))
    }

    func testPinchTranslationHasOneOwner() {
        XCTAssertEqual(
            CanvasGestureRouting.pinchPanTranslation(
                translation: CGPoint(x: 18, y: -7), suppressingAfterPinch: false
            ),
            CGPoint(x: 18, y: -7)
        )
        XCTAssertNil(CanvasGestureRouting.pinchPanTranslation(
            translation: CGPoint(x: 18, y: -7), suppressingAfterPinch: true
        ))
    }

    @MainActor
    private func normalizedCentreReportedByGestureSurface(size: CGSize) async throws -> NormalizedPoint {
        let sizeReported = expectation(description: "gesture surface reported its UIKit bounds")
        var reportedSize: CGSize?
        let surface = GestureSurfaceView(frame: CGRect(origin: .zero, size: size))
        surface.handlers = .init(
            onTouchDown: { _ in },
            onTouchMove: { _ in },
            onTouchUp: { _ in },
            onSecondaryClick: { _ in },
            onScroll: { _ in },
            onZoom: { _, _ in },
            onPanCanvas: { _ in },
            onSizeChange: {
                reportedSize = $0
                sizeReported.fulfill()
            }
        )

        surface.setNeedsLayout()
        surface.layoutIfNeeded()
        await fulfillment(of: [sizeReported], timeout: 1)

        let bounds = try XCTUnwrap(reportedSize)
        return try XCTUnwrap(CanvasGeometry.normalized(
            point: CGPoint(x: bounds.width / 2, y: bounds.height / 2),
            bounds: bounds,
            pixelSize: CGSize(width: 1800, height: 1168),
            zoom: 1,
            pan: .zero
        ))
    }

    // MARK: - Session awareness

    // A banner is a claim the user cannot check against anything, made at a moment they are
    // not looking. These pin what gets claimed — and mostly what does not, because only three
    // transitions out of the whole state machine are worth an interruption, and the events
    // that are not are the ones a reconnect loop would turn into a stream of banners.

    func testAReadySessionThatFailsNotifies() {
        let notification = SessionAwareness.notification(
            from: .ready,
            to: .failed("The Mac stopped responding."),
            hostName: "Studio",
            deliberate: false
        )

        XCTAssertNotNil(notification)
    }

    func testAReadySessionThatDropsNotifies() {
        let notification = SessionAwareness.notification(
            from: .ready,
            to: .disconnected,
            hostName: "Studio",
            deliberate: false
        )

        XCTAssertNotNil(notification)
    }

    /// Six digits are worth one banner, not one per phase the session passed through on its
    /// way to showing them: both routes into the prompt produce the same notification, so a
    /// session that arrives there twice replaces its own banner instead of stacking a second
    /// one behind it.
    func testThePairingCodeNotifiesExactlyOnce() {
        let afterConnecting = SessionAwareness.notification(
            from: .connecting,
            to: .confirming(code: "419302"),
            hostName: "Studio",
            deliberate: false
        )
        let afterHandshaking = SessionAwareness.notification(
            from: .handshaking,
            to: .confirming(code: "419302"),
            hostName: "Studio",
            deliberate: false
        )

        XCTAssertNotNil(afterConnecting)
        XCTAssertEqual(afterConnecting, afterHandshaking)
    }

    /// The model sets `.disconnected` itself and the session then reports one of its own, so
    /// the second delivery — which arrives with the phase already equal to the one it carries
    /// — must not read as the transition it is not.
    func testARepeatedPhaseIsNotATransition() {
        XCTAssertNil(SessionAwareness.notification(
            from: .ready, to: .ready, hostName: "Studio", deliberate: false
        ))
        XCTAssertNil(SessionAwareness.notification(
            from: .disconnected, to: .disconnected, hostName: "Studio", deliberate: false
        ))
    }

    func testConnectingNotifiesNobody() {
        XCTAssertNil(SessionAwareness.notification(
            from: .idle, to: .connecting, hostName: "Studio", deliberate: false
        ))
        XCTAssertNil(SessionAwareness.notification(
            from: .connecting, to: .handshaking, hostName: "Studio", deliberate: false
        ))
    }

    /// The user tapping Disconnect and the Mac vanishing are the same phase, and a banner
    /// telling someone what they just did is the notification equivalent of an echo.
    func testAUserEndedConnectionIsNotAConnectionLost() {
        XCTAssertNil(SessionAwareness.notification(
            from: .ready, to: .disconnected, hostName: "Studio", deliberate: true
        ))
    }

    /// A tab is one colour, so the four things a terminal can be have to be weighed rather than
    /// drawn together. This is that order, and it is the whole of what a tab says.
    func testATerminalSaysTheMostUrgentThingAboutIt() {
        var terminal = RemoteTerminal(id: UUID(), name: "Terminal 1", isRunning: true)
        // Opened, and the login shell has not printed its prompt yet.
        XCTAssertEqual(terminal.state, .starting)

        terminal.output = Data("ready\n".utf8)
        XCTAssertEqual(terminal.state, .running)

        terminal.attention = .password
        XCTAssertEqual(terminal.state, .attention(.password))

        // Waiting on the user outranks being broken, because only one of the two is something
        // the user can do anything about.
        terminal.failure = "Could not write to the terminal."
        XCTAssertEqual(terminal.state, .attention(.password))

        terminal.attention = nil
        XCTAssertEqual(terminal.state, .failed("Could not write to the terminal."))

        terminal.failure = nil
        terminal.isRunning = false
        // Ended, not broken. `exit` is a thing shells do, and a tab that cried wolf at every
        // one of them would be a tab nobody reads.
        XCTAssertEqual(terminal.state, .stopped)
    }

}

// MARK: - Subscription offers

/// When the app asks the user to subscribe, and how often.
///
/// This is the part that can be wrong in a way nobody notices. An offer that never arrives costs
/// a sale silently, and one that arrives twice is a nag the user has no switch for — both look
/// exactly like the feature working, from inside the app, until somebody complains. So the
/// decision is tested here rather than left to the screen that carries it.
final class SessionOfferTests: XCTestCase {
    /// Both of the keys the offers are remembered by, cleared before every test.
    ///
    /// They are `UserDefaults`, which outlives a test method and is shared by all of them: without
    /// this, whichever test ran first would decide whether the next one passed, and the failure
    /// would point at the wrong thing.
    override func setUp() {
        super.setUp()
        UserDefaults.standard.removeObject(forKey: PreferenceKey.offeredAfterFirstSession)
        UserDefaults.standard.removeObject(forKey: PreferenceKey.lowRelayOfferWindow)
    }

    /// A finished session, ending now so that the window it falls in is the current one.
    private func record(
        path: ClientSessionRecord.Path,
        duration: TimeInterval
    ) -> ClientSessionRecord {
        let endedAt = Date()
        return ClientSessionRecord(
            id: UUID(),
            hostID: nil,
            hostName: "Studio",
            startedAt: endedAt.addingTimeInterval(-duration),
            endedAt: endedAt,
            path: path,
            videoBytesReceived: 0,
            logs: []
        )
    }

    /// Long enough for an armed offer to have been shown, with room for a slow machine.
    private func waitForArmedOffer() async {
        try? await Task.sleep(for: .seconds(SessionModel.offerAfterSessionDelay + 0.4))
    }

    // MARK: RelayTime

    func testRelayTimeReadsAsSecondsUnderAMinute() {
        XCTAssertEqual(RelayTime.label(0), "0s")
        XCTAssertEqual(RelayTime.label(12), "12s")
        XCTAssertEqual(RelayTime.label(59), "59s")
    }

    func testRelayTimeReadsAsMinutesAndSecondsUnderAnHour() {
        XCTAssertEqual(RelayTime.label(60), "1m 0s")
        XCTAssertEqual(RelayTime.label(72), "1m 12s")
        XCTAssertEqual(RelayTime.label(3599), "59m 59s")
    }

    /// Past an hour the seconds are dropped, so a reader gets a level rather than a stopwatch.
    func testRelayTimeDropsTheSecondsOnceThereAreHours() {
        XCTAssertEqual(RelayTime.label(3600), "1h")
        XCTAssertEqual(RelayTime.label(3660), "1h 1m")
        XCTAssertEqual(RelayTime.label(9720), "2h 42m")
        XCTAssertEqual(RelayTime.label(10800), "3h")
    }

    /// Below zero is not a duration, and the arithmetic that feeds this can produce one even
    /// though the estimate it reads clamps at zero.
    func testRelayTimeClampsBelowZero() {
        XCTAssertEqual(RelayTime.label(-1), "0s")
        XCTAssertEqual(RelayTime.label(-900), "0s")
    }

    // MARK: The decision

    /// The connect that was a mistake, and the one that dropped on arrival. Both reach this with a
    /// record, because both reached `.ready` — which is what the floor is for.
    @MainActor
    func testASessionTooShortToHaveBeenUsedIsNotOffered() {
        let model = SessionModel()
        model.offerSubscriptionIfDue(after: record(path: .lan, duration: 4))
        XCTAssertNil(model.pendingOffer)
    }

    @MainActor
    func testTheFirstRealSessionIsOffered() async {
        let model = SessionModel()
        model.offerSubscriptionIfDue(after: record(path: .lan, duration: 90))

        // The decision is made on the teardown and the showing is held back, so these are two
        // separate things to be wrong.
        XCTAssertNotNil(model.pendingOffer)
        await waitForArmedOffer()

        guard case .firstSession? = model.paywallReason else {
            return XCTFail("expected the first-session door, got \(String(describing: model.paywallReason))")
        }
        XCTAssertTrue(model.hasOfferedAfterFirstSession)
    }

    @MainActor
    func testTheFirstSessionIsOfferedOnlyOnceEver() async {
        let model = SessionModel()
        model.offerSubscriptionIfDue(after: record(path: .lan, duration: 90))
        await waitForArmedOffer()
        XCTAssertTrue(model.hasOfferedAfterFirstSession)

        // Dismissed, and then a second session ends. The door has been through once.
        model.paywallReason = nil
        model.offerSubscriptionIfDue(after: record(path: .lan, duration: 90))
        XCTAssertNil(model.pendingOffer)
    }

    /// Free is half an hour a day, so twenty-five minutes spent leaves five — under the quarter
    /// that ``SessionModel/lowRelayAllowanceFraction`` calls running low.
    @MainActor
    func testARelaySessionThatLeavesTheAllowanceLowIsOffered() async {
        let model = SessionModel()
        model.hasOfferedAfterFirstSession = true
        model.sessionHistory = [record(path: .relay, duration: 1500)]

        model.offerSubscriptionIfDue(after: record(path: .relay, duration: 60))
        await waitForArmedOffer()

        guard case .runningLow(let remaining)? = model.paywallReason else {
            return XCTFail("expected the running-low door, got \(String(describing: model.paywallReason))")
        }
        XCTAssertEqual(remaining, 300, accuracy: 1)
        XCTAssertEqual(model.lowRelayOfferWindow, model.relayWindowNumber)
    }

    /// Spent and nearly spent are different sentences, and at zero only one of them is true.
    @MainActor
    func testSpendingTheLastOfTheAllowanceGetsTheWallRatherThanTheWarning() async {
        let model = SessionModel()
        model.hasOfferedAfterFirstSession = true
        model.sessionHistory = [record(path: .relay, duration: 1800)]

        model.offerSubscriptionIfDue(after: record(path: .relay, duration: 60))
        await waitForArmedOffer()

        guard case .quotaExhausted? = model.paywallReason else {
            return XCTFail("expected the wall, got \(String(describing: model.paywallReason))")
        }
    }

    /// A session that spent no relay, on a day whose relay is nearly gone. The meter has not moved
    /// because of this session, and the Sessions tab is already saying the same figure.
    @MainActor
    func testASessionThatSpentNoRelayIsNotAnExcuseToSell() {
        let model = SessionModel()
        model.hasOfferedAfterFirstSession = true
        model.sessionHistory = [record(path: .relay, duration: 1700)]

        model.offerSubscriptionIfDue(after: record(path: .lan, duration: 120))
        XCTAssertNil(model.pendingOffer)
    }

    @MainActor
    func testTheRunningLowOfferIsMadeOncePerWindow() async {
        let model = SessionModel()
        model.hasOfferedAfterFirstSession = true
        model.sessionHistory = [record(path: .relay, duration: 1500)]

        model.offerSubscriptionIfDue(after: record(path: .relay, duration: 60))
        await waitForArmedOffer()
        XCTAssertNotNil(model.paywallReason)

        model.paywallReason = nil
        model.offerSubscriptionIfDue(after: record(path: .relay, duration: 60))
        XCTAssertNil(model.pendingOffer, "one window is one asking")
    }

    /// The paywall the user opened themselves is already on screen. There is one `paywallReason`,
    /// and replacing it would rewrite the screen being read.
    @MainActor
    func testAnOpenPaywallIsNotOverwrittenByAnOffer() {
        let model = SessionModel()
        model.paywallReason = .upgrade

        model.offerSubscriptionIfDue(after: record(path: .lan, duration: 90))
        XCTAssertNil(model.pendingOffer)
    }
}
