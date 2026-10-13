//
//  PeeringPolicyTests.swift
//  PeeringKitTests
//
//  Created by Damian Derlecki on 13/09/2026.
//

import AVFoundation
import CoreGraphics
import RemoteCore
import XCTest
@testable import PeeringKit

/// The app's own policy, tested where it can run. Moved here from `PeeringTests` because Xcode 27 cannot execute that test action (the Crypto product's target never runs a link step, so X509, RemoteCore and the app fail to link). Runs under `swift test`; the two tests needing UIKit stay in `PeeringTests`.
/// `@MainActor`: the app builds with `SWIFT_DEFAULT_ACTOR_ISOLATION = MainActor`, so these are main-actor types there.
@MainActor
final class PeeringPolicyTests: XCTestCase {

    // MARK: - Auto quality

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

    // MARK: - The bitrate preset

    func testManualQualityOffersEveryPresetButAutomatic() {
        // `auto` belongs to the mode picker, so a preset in both lists would be two controls for one setting.
        XCTAssertEqual(StreamQuality.manualCases, [.low, .medium, .high])
    }

    func testTakingTheRateOverByHandStartsWhereAutomaticHadIt() {
        // `setAutomaticQuality` hands the policy's tier to the manual picker; a tier and the preset naming it are separate enums that must agree on the rate.
        for tier in [AutoQualityPolicy.Tier.low, .medium, .high] {
            let preset = StreamQuality(tier)
            XCTAssertEqual(preset.bitrateKbps, tier.bitrateKbps)
        }
    }

    func testEveryQualityPresetSurvivesBeingStoredAndReadBack() {
        // A preset that did not round-trip would silently come back as something else: `storedQuality` reads an undecodable token as nothing stored.
        for preset in StreamQuality.allCases {
            XCTAssertEqual(StreamQuality(rawValue: preset.rawValue), preset)
        }
    }

    func testTheWordsOnTheChipAreNotWhatIsStored() {
        // `chipTitle` is deliberately not the raw value: keying a saved preference on a chip abbreviation would reset every stored value to automatic the day it changed. Decoding the old spellings to `nil` is intended (nothing wrote them under this key).
        for preset in StreamQuality.allCases {
            XCTAssertNil(StreamQuality(rawValue: preset.chipTitle))
        }
        XCTAssertNil(StreamQuality(rawValue: "Med"))
        XCTAssertNil(StreamQuality(rawValue: ""))
    }

    func testTheChipStillSpellsTheFourWordsItAlwaysDid() {
        XCTAssertEqual(StreamQuality.auto.chipTitle, "Auto")
        XCTAssertEqual(StreamQuality.low.chipTitle, "Low")
        XCTAssertEqual(StreamQuality.medium.chipTitle, "Med")
        XCTAssertEqual(StreamQuality.high.chipTitle, "High")
    }

    func testTheQualityMenuNamesTheRateItIsOffering() {
        // All four are written out rather than checked with `contains`: `auto`'s entry says what it follows, not "Automatic". They are what the menu actually draws.
        XCTAssertEqual(StreamQuality.auto.menuTitle, "Auto, follows the network")
        XCTAssertEqual(StreamQuality.low.menuTitle, "Low, 2 Mbps")
        XCTAssertEqual(StreamQuality.medium.menuTitle, "Medium, 8 Mbps")
        XCTAssertEqual(StreamQuality.high.menuTitle, "High, 20 Mbps")

        for preset in StreamQuality.allCases {
            XCTAssertTrue(
                preset.menuTitle.contains(preset.chipTitle) || preset.menuTitle.contains(preset.title),
                "\(preset.menuTitle) names neither \(preset.chipTitle) nor \(preset.title)"
            )
        }
    }

    // MARK: - Sample attachments

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
        return try XCTUnwrap(VideoSampleBuffer.make(frame, format: try XCTUnwrap(format)))
    }

    /// Sample level, not buffer level: `CMGetAttachment` reads the buffer-level bearer and answered `nil` for all three keys, so every assertion once compared `nil` and checked nothing.
    private func attachmentBool(_ sample: CMSampleBuffer, _ key: CFString) -> Bool? {
        guard let attachments = CMSampleBufferGetSampleAttachmentsArray(
            sample, createIfNecessary: false
        ), CFArrayGetCount(attachments) > 0,
          let entry = CFArrayGetValueAtIndex(attachments, 0)
        else { return nil }

        let dictionary = Unmanaged<CFDictionary>.fromOpaque(entry).takeUnretainedValue()
        guard let value = CFDictionaryGetValue(
            dictionary, Unmanaged.passUnretained(key).toOpaque()
        ) else { return nil }
        return CFBooleanGetValue(Unmanaged<CFBoolean>.fromOpaque(value).takeUnretainedValue())
    }

    // MARK: - The picture under the zoom

    /// A config comes down on every channel switch, re-attach and encoder rebuild, all the same source at the same size; reading those as a source change would jump the picture.
    func testTheSameStreamDescribedAgainIsNotANewPicture() {
        XCTAssertEqual(
            picture("display:1", 3024, 1964).change(to: picture("display:1", 3024, 1964)),
            .unchanged
        )
    }

    func testAResizedWindowKeepsItsMagnification() {
        XCTAssertEqual(
            picture("window:7", 580, 384, movesOnItsOwn: true)
                .change(to: picture("window:7", 902, 640, movesOnItsOwn: true)),
            .resized
        )
    }

    /// A display's surface is fixed for a stream, so a new size is a different display or mode, not a resize.
    func testADisplayAtANewSizeIsNotThePictureTheZoomWasChosenFor() {
        XCTAssertEqual(
            picture("display:1", 3024, 1964).change(to: picture("display:1", 1512, 982)),
            .replaced
        )
    }

    /// Two identical monitors are why the size is not the identity.
    func testASwitchBetweenTwoSourcesOfTheSameSizeIsStillASwitch() {
        XCTAssertEqual(
            picture("display:1", 2560, 1440).change(to: picture("display:2", 2560, 1440)),
            .replaced
        )
    }

    /// A picture described before the catalogue arrived is nameless; the name catching up is not a switch (every session starts so, and a reset would drop the user's zoom).
    func testAPictureThatEarnsItsNameIsNotASourceChange() {
        XCTAssertEqual(
            picture(nil, 580, 384, movesOnItsOwn: true)
                .change(to: picture("window:7", 580, 384, movesOnItsOwn: true)),
            .unchanged
        )
    }

    /// A source with no catalogue entry is unknown and read as free to move: keeping a stale magnification costs one pinch, dropping one costs the user their place.
    func testASourceWithNoCatalogueEntryIsOneWeCannotKnowIsFixed() {
        let display = CaptureSourceDescriptor(
            kind: .display,
            title: "Built-in Display",
            source: .display(1),
            pixelSize: CGSize(width: 3024, height: 1964)
        )
        let catalog = CaptureCatalog(displays: [display])

        XCTAssertTrue(PictureIdentity.forStream(
            config(580, 384, sourceID: "window:99"), catalog: catalog
        ).contentMovesOnItsOwn)

        XCTAssertFalse(PictureIdentity.forStream(
            config(3024, 1964, sourceID: display.id), catalog: catalog
        ).contentMovesOnItsOwn)
    }

    func testTheConfigSourceWinsOverTheMostRecentRequest() {
        let identity = PictureIdentity.forStream(
            config(1290, 1212, sourceID: "mosaic:answer"),
            catalog: nil,
            source: .mosaic(MosaicLayout(
                canvas: CGSize(width: 1290, height: 1212), tiles: [], frameRate: 15
            ))
        )

        XCTAssertEqual(identity.sourceID, "mosaic:answer")
    }

    func testACanvasThatCameBackARoundingIsStillTheArrangementThatWasAskedFor() {
        // The Mac rounds the canvas down to even, so an odd-size arrangement comes back a pixel narrower: same picture, tiles stay clickable.
        XCTAssertTrue(
            CGSize(width: 1291, height: 1213).matchesCanvas(CGSize(width: 1290, height: 1212))
        )
        XCTAssertFalse(
            CGSize(width: 1290, height: 1088).matchesCanvas(CGSize(width: 1290, height: 1212))
        )
    }

    private func picture(
        _ sourceID: String?,
        _ width: Int,
        _ height: Int,
        movesOnItsOwn: Bool = false
    ) -> PictureIdentity {
        PictureIdentity(
            sourceID: sourceID,
            pixelSize: CGSize(width: width, height: height),
            contentMovesOnItsOwn: movesOnItsOwn
        )
    }

    private func config(_ width: Int, _ height: Int, sourceID: String = "display:1") -> VideoStreamConfig {
        VideoStreamConfig(
            sourceID: sourceID,
            codec: .h264,
            pixelWidth: width,
            pixelHeight: height,
            parameterSets: [Data([0x00])]
        )
    }

    // MARK: - Canvas geometry

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

    func testViewAndScrollTouchesReachTheMac() {
        let mode = InteractionMode.control

        XCTAssertFalse(mode.oneFingerDragPansCanvas)
        XCTAssertTrue(mode.tapsReachTheMac)
    }

    /// Looking closer is not a mode: `CanvasGeometry.normalized` undoes zoom and pan, so the pinch works in both modes and the mode only decides whether a drag pans.
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

    /// A drag either moves the picture or is sent to the Mac, never both, over every case so a new mode cannot be both.
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

    /// The switch is stored as its raw value, so that string is a persistence format; the default must match the pre-switch behaviour.
    func testInteractionModeRoundTripsThroughItsStoredValue() {
        for mode in InteractionMode.allCases {
            XCTAssertEqual(InteractionMode(rawValue: mode.rawValue), mode)
        }

        XCTAssertEqual(InteractionMode(rawValue: "control"), .control)
        XCTAssertEqual(InteractionMode(rawValue: "navigate"), .control)
        XCTAssertNil(InteractionMode(rawValue: "dragging"))
    }

    func testEachModeIsDistinguishableOnItsButton() {
        XCTAssertEqual(Set(InteractionMode.allCases.map(\.label)).count, InteractionMode.allCases.count)
        XCTAssertEqual(Set(InteractionMode.allCases.map(\.symbol)).count, InteractionMode.allCases.count)
    }

    // MARK: - Pinch and pan arbitration

    /// UIKit may end the pinch before its pan: translation accumulated while pinching must already be gone, or the pan delivers the pinch as one jump on release.
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

    // MARK: - The scroll wheel

    func testANotchIsAFixedAmountOfTravelAndOfDocument() {
        var wheel = ScrollWheelState()

        XCTAssertEqual(wheel.roll(points: ScrollNotch.travel), 1)
        for _ in 0..<11 { XCTAssertEqual(wheel.roll(points: 1), 0) }
        XCTAssertEqual(wheel.delivered, 1)
        XCTAssertEqual(wheel.roll(points: 1), 1)
        XCTAssertEqual(wheel.delivered, 2)

        XCTAssertEqual(ScrollNotch.pixels, 24)

        XCTAssertEqual(wheel.roll(points: 6), 0)
        XCTAssertEqual(wheel.phase, 2.5, accuracy: 0.0001)
        XCTAssertEqual(wheel.delivered, 2)
    }

    func testADragThatTurnsRoundTakesTheNotchesBack() {
        var wheel = ScrollWheelState()

        XCTAssertEqual(wheel.roll(points: 6), 0)
        XCTAssertEqual(wheel.roll(points: -6), 0)
        XCTAssertEqual(wheel.phase, 0, accuracy: 0.0001)
        XCTAssertEqual(wheel.delivered, 0)

        XCTAssertEqual(wheel.roll(points: ScrollNotch.travel + 3), 1)
        XCTAssertEqual(wheel.roll(points: -ScrollNotch.travel - 3), -1)
        XCTAssertEqual(wheel.delivered, 0)
    }

    func testTheWheelSeatsItselfSoAnArrowAlwaysDeliversANotch() {
        var wheel = ScrollWheelState()

        // Let go past halfway and the spring finishes the notch; short of halfway it springs back.
        XCTAssertEqual(wheel.roll(points: ScrollNotch.travel / 2 + 1), 0)
        XCTAssertEqual(wheel.seat(), 1)
        XCTAssertEqual(wheel.phase, 1, accuracy: 0.0001)

        XCTAssertEqual(wheel.roll(points: ScrollNotch.travel / 2 - 1), 0)
        XCTAssertEqual(wheel.seat(), 0)
        XCTAssertEqual(wheel.phase, 1, accuracy: 0.0001)

        XCTAssertEqual(wheel.roll(notches: -1), -1)
        XCTAssertEqual(wheel.delivered, 0)
    }

    func testAFlickCarriesAPageAndThenStops() {
        // A hard flick is capped: a phone flick is about a thousand points a second, eighty notches before coasting starts.
        let launch = WheelSpin.launch(pointsPerSecond: 5_000)
        XCTAssertEqual(launch, WheelSpin.launchLimit)

        // At the cap the coast is about a page and ends: the rate at the end of the duration is the stalling rate.
        XCTAssertEqual(WheelSpin.travel(launch) * ScrollNotch.pixels, 995, accuracy: 15)
        XCTAssertEqual(WheelSpin.rate(launch, after: WheelSpin.duration(launch)), WheelSpin.stalling, accuracy: 0.001)

        // A gentle drag does not coast: the wheel has to be turning to keep turning.
        let slow = WheelSpin.launch(pointsPerSecond: 10)
        XCTAssertEqual(slow, 10 / ScrollNotch.travel, accuracy: 0.0001)
        XCTAssertEqual(WheelSpin.duration(slow), 0)
    }

    // MARK: - Session awareness

    /// An identifier fixed per kind lets two Macs ending sessions at once overwrite each other's banner (losing a pairing code), so it includes the Mac.
    func testTwoMacsBannersDoNotReplaceEachOther() {
        let one = SessionAwareness.Notification(
            kind: .awaitingPairingCode, title: "Pairing with Studio", body: "…", hostID: "AAAAAA"
        )
        let other = SessionAwareness.Notification(
            kind: .awaitingPairingCode, title: "Pairing with Attic", body: "…", hostID: "BBBBBB"
        )

        XCTAssertNotEqual(one.identifier, other.identifier)
    }

    func testTheSameMacAndKindStillReplacesItself() {
        let first = SessionAwareness.Notification(
            kind: .awaitingPairingCode, title: "Pairing with Studio", body: "…", hostID: "AAAAAA"
        )
        let second = SessionAwareness.Notification(
            kind: .awaitingPairingCode, title: "Pairing with Studio", body: "…", hostID: "AAAAAA"
        )

        XCTAssertEqual(first.identifier, second.identifier)
    }

    func testABannerWithNoMacKeepsTheKindIdentifier() {
        let notification = SessionAwareness.Notification(
            kind: .connected, title: "Connected", body: "…"
        )

        XCTAssertEqual(notification.identifier, SessionAwareness.Kind.connected.identifier)
    }

    func testTheRuleCarriesTheHostItWasGiven() {
        let notification = SessionAwareness.notification(
            from: .handshaking,
            to: .confirming(code: "419302"),
            hostName: "Studio",
            hostID: "7C4E422B",
            deliberate: false
        )

        XCTAssertEqual(notification?.hostID, "7C4E422B")
        XCTAssertTrue(notification?.identifier.hasSuffix("7C4E422B") == true)
    }

    func testAReadySessionThatFailsNotifies() {
        let notification = SessionAwareness.notification(
            from: .ready,
            to: .failed("The Mac stopped responding."),
            hostName: "Studio",
            deliberate: false
        )

        XCTAssertNotNil(notification)
    }

    /// A drop the app is already putting back is not news.
    func testADropThatIsBeingResumedIsNotNotified() {
        let notification = SessionAwareness.notification(
            from: .ready,
            to: .failed("The Mac stopped answering."),
            hostName: "Studio",
            deliberate: false,
            resuming: true
        )

        XCTAssertNil(notification)
    }

    /// Neither is the reconnect that follows it (a background/foreground cycle tears the socket down and puts it back).
    func testAResumeThatSucceedsIsNotNotified() {
        let notification = SessionAwareness.notification(
            from: .connecting,
            to: .ready,
            hostName: "Studio",
            deliberate: false,
            resuming: true
        )

        XCTAssertNil(notification)
    }

    /// Suppression covers exactly those two cases: a failure on the way to a connection still gets banner text, and a user-ended session is not a resume.
    func testAFailureThatIsNotAResumeStillNotifies() {
        let onTheWay = SessionAwareness.notification(
            from: .connecting,
            to: .failed("The Mac refused the connection."),
            hostName: "Studio",
            deliberate: false
        )
        let userEnded = SessionAwareness.notification(
            from: .ready,
            to: .failed("The connection ended."),
            hostName: "Studio",
            deliberate: true
        )

        XCTAssertNotNil(onTheWay)
        XCTAssertNotNil(userEnded, "a deliberate end is not a resume, whatever the caller passes")
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

    /// Both routes into the prompt produce the same notification, so a session arriving twice replaces its banner.
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

    /// The model sets `.disconnected` itself and the session then reports one: the second delivery, with the phase already equal, must not read as a transition.
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

    func testAUserEndedConnectionIsNotAConnectionLost() {
        XCTAssertNil(SessionAwareness.notification(
            from: .ready, to: .disconnected, hostName: "Studio", deliberate: true
        ))
    }

    func testATerminalSaysTheMostUrgentThingAboutIt() {
        var terminal = RemoteTerminal(id: UUID(), name: "Terminal 1", isRunning: true)
        XCTAssertEqual(terminal.state, .starting)

        terminal.output = Data("ready\n".utf8)
        XCTAssertEqual(terminal.state, .running)

        terminal.attention = .password
        XCTAssertEqual(terminal.state, .attention(.password))

        // Waiting on the user outranks broken: only one is actionable.
        terminal.failure = "Could not write to the terminal."
        XCTAssertEqual(terminal.state, .attention(.password))

        terminal.attention = nil
        XCTAssertEqual(terminal.state, .failed("Could not write to the terminal."))

        terminal.failure = nil
        terminal.isRunning = false
        // Ended, not broken: `exit` is normal and must not cry wolf.
        XCTAssertEqual(terminal.state, .stopped)
    }

    // MARK: - Relay time

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

    func testRelayTimeDropsTheSecondsOnceThereAreHours() {
        XCTAssertEqual(RelayTime.label(3600), "1h")
        XCTAssertEqual(RelayTime.label(3660), "1h 1m")
        XCTAssertEqual(RelayTime.label(9720), "2h 42m")
        XCTAssertEqual(RelayTime.label(10800), "3h")
    }

    /// Below zero is not a duration, though the arithmetic feeding this can produce one.
    func testRelayTimeClampsBelowZero() {
        XCTAssertEqual(RelayTime.label(-1), "0s")
        XCTAssertEqual(RelayTime.label(-900), "0s")
    }

    // MARK: - The stored preference

    /// A defaults store of this test's own, since saving and restoring `UserDefaults.standard` fails when another test runs beside it.
    private func scratchDefaults(_ name: String = #function) throws -> UserDefaults {
        let suite = "PeeringKitTests.\(name)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defaults.removePersistentDomain(forName: suite)
        addTeardownBlock { defaults.removePersistentDomain(forName: suite) }
        return defaults
    }

    /// A key never written (every install predating the setting) and a token from a future version both answer automatic, the pre-setting behaviour.
    func testAnUnrecognisedQualityFallsBackToAutomatic() throws {
        let defaults = try scratchDefaults()

        XCTAssertEqual(StreamQuality.stored(in: defaults), .auto)

        defaults.set("ultra", forKey: PreferenceKeys.streamQuality)
        XCTAssertEqual(StreamQuality.stored(in: defaults), .auto)

        defaults.set(StreamQuality.medium.rawValue, forKey: PreferenceKeys.streamQuality)
        XCTAssertEqual(StreamQuality.stored(in: defaults), .medium)
    }

    /// The Settings tab writes the preference but cannot reach the model, which is built once per process, so its copy of the preset is stale from launch; arrival decides from the store.
    func testASessionStartsAtWhatTheSettingsTabStored() throws {
        let defaults = try scratchDefaults()

        defaults.set(StreamQuality.high.rawValue, forKey: PreferenceKeys.streamQuality)
        XCTAssertEqual(StreamQuality.stored(in: defaults), .high)
        XCTAssertEqual(StreamQuality.storedManualLevel(in: defaults), .high)

        defaults.set(StreamQuality.auto.rawValue, forKey: PreferenceKeys.streamQuality)
        XCTAssertEqual(StreamQuality.stored(in: defaults), .auto)
        XCTAssertNil(StreamQuality.storedManualLevel(in: defaults))
    }
}

// MARK: - Subscription offers

/// When the app asks the user to subscribe, and how often. A missing offer costs a sale silently and a doubled one is a nag, both invisible from inside the app, so the decision (not the showing) is tested here.
@MainActor
final class SessionOfferPolicyTests: XCTestCase {
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

    private func state(
        hasOfferedAfterFirstSession: Bool = false,
        planIsUnlimited: Bool = false,
        hasPaywallOpen: Bool = false,
        hasPendingOffer: Bool = false,
        allowanceFraction: Double? = nil,
        remaining: TimeInterval? = nil,
        currentWindow: Double = 20_000,
        offeredWindow: Double = 0
    ) -> SessionOfferPolicy.State {
        SessionOfferPolicy.State(
            hasOfferedAfterFirstSession: hasOfferedAfterFirstSession,
            planIsUnlimited: planIsUnlimited,
            hasPaywallOpen: hasPaywallOpen,
            hasPendingOffer: hasPendingOffer,
            relayAllowanceRemainingFraction: allowanceFraction,
            relaySecondsRemainingEstimate: remaining,
            currentWindow: currentWindow,
            offeredWindow: offeredWindow
        )
    }

    /// Three minutes left, under the ``SessionOfferPolicy/lowRelayAllowanceFraction`` quarter; read off ``RelayPlan`` because this number has moved once.
    private var nearlySpent: Double { 180.0 / (RelayPlan.free.allowanceSeconds ?? 1) }

    func testASessionTooShortToHaveBeenUsedIsNotOffered() {
        XCTAssertNil(SessionOfferPolicy.decision(
            after: record(path: .lan, duration: 4), state: state()
        ))
    }

    func testTheFirstRealSessionIsOffered() {
        let decision = SessionOfferPolicy.decision(
            after: record(path: .lan, duration: 90), state: state()
        )

        XCTAssertEqual(decision?.reason, .firstSession)
        XCTAssertEqual(decision?.consumption, .firstSession)
    }

    /// Someone who never finished a session gets the whole case, not the running-low version, even if already low. The two offers are ordered, not ranked.
    func testTheFirstSessionIsOfferedTheWholeCaseRatherThanTheRunningLowOne() {
        let decision = SessionOfferPolicy.decision(
            after: record(path: .relay, duration: 90),
            state: state(allowanceFraction: 0.02, remaining: 30)
        )

        XCTAssertEqual(decision?.reason, .firstSession)
        XCTAssertEqual(decision?.consumption, .firstSession)
    }

    func testTheFirstSessionIsOfferedOnlyOnceEver() {
        XCTAssertNil(SessionOfferPolicy.decision(
            after: record(path: .lan, duration: 90),
            state: state(hasOfferedAfterFirstSession: true)
        ))
    }

    func testARelaySessionThatLeavesTheAllowanceLowIsOffered() {
        let decision = SessionOfferPolicy.decision(
            after: record(path: .relay, duration: 60),
            state: state(
                hasOfferedAfterFirstSession: true,
                allowanceFraction: nearlySpent,
                remaining: 180
            )
        )

        XCTAssertEqual(decision?.reason, .runningLow(remaining: 180))
        XCTAssertEqual(decision?.consumption, .lowAllowance)
    }

    func testSpendingTheLastOfTheAllowanceGetsTheWallRatherThanTheWarning() {
        let decision = SessionOfferPolicy.decision(
            after: record(path: .relay, duration: 60),
            state: state(
                hasOfferedAfterFirstSession: true,
                allowanceFraction: 0,
                remaining: 0
            )
        )

        XCTAssertEqual(decision?.reason, .quotaExhausted)
    }

    func testASessionThatSpentNoRelayIsNotAnExcuseToSell() {
        XCTAssertNil(SessionOfferPolicy.decision(
            after: record(path: .lan, duration: 120),
            state: state(
                hasOfferedAfterFirstSession: true,
                allowanceFraction: 0.05,
                remaining: 90
            )
        ))
    }

    func testTheRunningLowOfferIsMadeOncePerWindow() {
        let spent = state(
            hasOfferedAfterFirstSession: true,
            allowanceFraction: nearlySpent,
            remaining: 300,
            currentWindow: 20_000,
            offeredWindow: 20_000
        )
        XCTAssertNil(
            SessionOfferPolicy.decision(after: record(path: .relay, duration: 60), state: spent),
            "one window is one asking"
        )

        let nextWindow = state(
            hasOfferedAfterFirstSession: true,
            allowanceFraction: nearlySpent,
            remaining: 300,
            currentWindow: 20_001,
            offeredWindow: 20_000
        )
        XCTAssertNotNil(
            SessionOfferPolicy.decision(after: record(path: .relay, duration: 60), state: nextWindow)
        )
    }

    /// The user-opened paywall is on screen; there is one `paywallReason` and replacing it would rewrite the screen being read.
    func testAnOpenPaywallIsNotOverwrittenByAnOffer() {
        XCTAssertNil(SessionOfferPolicy.decision(
            after: record(path: .lan, duration: 90),
            state: state(hasPaywallOpen: true)
        ))
    }

    /// An offer still waiting out its half-second is headed for that same screen.
    func testAnOfferAlreadyInFlightIsNotReplacedByASecond() {
        XCTAssertNil(SessionOfferPolicy.decision(
            after: record(path: .lan, duration: 90),
            state: state(hasPendingOffer: true)
        ))
    }

    func testAnUnmeteredPlanIsOfferedNothingAtAll() {
        XCTAssertNil(SessionOfferPolicy.decision(
            after: record(path: .lan, duration: 90),
            state: state(planIsUnlimited: true)
        ))
        XCTAssertNil(SessionOfferPolicy.decision(
            after: record(path: .relay, duration: 90),
            state: state(
                planIsUnlimited: true,
                allowanceFraction: 0,
                remaining: 0
            )
        ))
    }
}

// MARK: - Session records

@MainActor
final class ClientSessionRecordTests: XCTestCase {
    private func encodedWithoutDirectPath() -> Data {
        // Exactly what the app wrote before `usedDirectPath`, `connectedSegments` and `endedDeliberately` existed.
        let json = """
        {
          "id": "3B4E4A5C-0000-4000-8000-000000000001",
          "hostName": "Studio",
          "startedAt": 760000000,
          "endedAt": 760000090,
          "path": "Relay",
          "videoBytesReceived": 1024,
          "logs": []
        }
        """
        return Data(json.utf8)
    }

    /// What one build wrote: connected seconds without the times they fell at.
    private func encodedWithATotalAndNoTimes() -> Data {
        let json = """
        {
          "id": "3B4E4A5C-0000-4000-8000-000000000002",
          "hostName": "Studio",
          "startedAt": 760000000,
          "endedAt": 760000090,
          "path": "Relay",
          "videoBytesReceived": 1024,
          "logs": [],
          "connectedSeconds": 30,
          "endedDeliberately": false
        }
        """
        return Data(json.utf8)
    }

    /// Records are read back from `UserDefaults`; a decoder requiring every key would drop the whole history on the first launch after an update.
    func testARecordWrittenBeforeThePathWasFiledStillDecodes() throws {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .secondsSince1970

        let record = try decoder.decode(
            ClientSessionRecord.self, from: encodedWithoutDirectPath()
        )

        XCTAssertEqual(record.hostName, "Studio")
        XCTAssertEqual(record.path, .relay)
        XCTAssertFalse(record.usedDirectPath, "an old record has to decode as one that did not punch")
    }

    /// Before a session could be continued nothing was merged, so connected time is its span, and it must behave so in the meter, not only decode.
    func testARecordWrittenWithoutConnectedTimeDecodesAsItsSpan() throws {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .secondsSince1970

        let record = try decoder.decode(
            ClientSessionRecord.self, from: encodedWithoutDirectPath()
        )

        XCTAssertEqual(record.duration, 90, "the two dates the fixture carries")
        XCTAssertEqual(record.connectedSeconds, record.duration)
        XCTAssertEqual(record.connectedSegments.count, 1, "one stretch, covering it end to end")
        XCTAssertEqual(record.connectedSegments.first?.start, record.startedAt)
        XCTAssertEqual(record.connectedSegments.first?.end, record.endedAt)
        // The window must be the one the record is in, or this tests the clock.
        XCTAssertEqual(
            RelayAllowance.secondsUsed(
                records: [record],
                windowStart: record.startedAt.addingTimeInterval(-60),
                liveRelaySegments: []
            ),
            90,
            "and the allowance spends all of it, which is what this record's app believed"
        )
        XCTAssertTrue(
            record.endedDeliberately,
            "no reconnect may claim a record written before a session could be continued"
        )
    }

    /// A record that kept the total but not the times puts its seconds at the end of the span; the figure must never change, or a session would be charged for its gap.
    func testARecordWrittenWithATotalAndNoTimesKeepsItsSeconds() throws {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .secondsSince1970

        let record = try decoder.decode(
            ClientSessionRecord.self, from: encodedWithATotalAndNoTimes()
        )

        XCTAssertEqual(record.connectedSeconds, 30, "the total it was filed with, to the second")
        XCTAssertEqual(record.duration, 90)
        XCTAssertTrue(record.wasInterrupted, "ninety seconds of span, thirty of them connected")
        XCTAssertEqual(
            RelayAllowance.secondsUsed(
                records: [record],
                windowStart: record.startedAt.addingTimeInterval(-60),
                liveRelaySegments: []
            ),
            30
        )
    }

    func testThePathSurvivesBeingWrittenAndReadBack() throws {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .secondsSince1970
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .secondsSince1970

        let record = ClientSessionRecord(
            id: UUID(),
            hostID: nil,
            hostName: "Studio",
            startedAt: Date(timeIntervalSince1970: 760_000_000),
            endedAt: Date(timeIntervalSince1970: 760_000_090),
            path: .relay,
            videoBytesReceived: 0,
            logs: [],
            usedDirectPath: true
        )

        let decoded = try decoder.decode(
            ClientSessionRecord.self, from: encoder.encode(record)
        )

        XCTAssertTrue(decoded.usedDirectPath)
        XCTAssertEqual(decoded.path, .relay, "a punched session is still a relay session to the meter")
    }

    /// Without these a record read back would be charged for its whole span, metered in the wrong window and continuable twice.
    func testConnectedTimeSurvivesBeingWrittenAndReadBack() throws {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .secondsSince1970
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .secondsSince1970

        let startedAt = Date(timeIntervalSince1970: 760_000_000)
        let resumedAt = Date(timeIntervalSince1970: 760_003_000)
        let record = ClientSessionRecord(
            id: UUID(),
            hostID: "3B4E4A5C",
            hostName: "Studio",
            startedAt: startedAt,
            endedAt: Date(timeIntervalSince1970: 760_003_600),
            path: .relay,
            videoBytesReceived: 0,
            logs: [],
            connectedSegments: [
                DateInterval(start: startedAt, duration: 300),
                DateInterval(start: resumedAt, duration: 600),
            ],
            endedDeliberately: true
        )

        let decoded = try decoder.decode(
            ClientSessionRecord.self, from: encoder.encode(record)
        )

        XCTAssertEqual(decoded.connectedSeconds, 900, "the two stretches, and not the hour of span")
        XCTAssertEqual(decoded.duration, 3_600)
        XCTAssertEqual(decoded.connectedSegments.count, 2, "and where they fell, or the window lies")
        XCTAssertEqual(decoded.connectedSegments.last?.start, resumedAt)
        XCTAssertTrue(decoded.endedDeliberately)
    }
}
