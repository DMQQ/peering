//
//  MacCastPolicyTests.swift
//  MacCastKitTests
//
//  Created by Damian Derlecki on 13/09/2026.
//

import AVFoundation
import CoreGraphics
import RemoteCore
import XCTest
@testable import MacCastKit

/// The app's own policy, tested where it can actually be run.
///
/// **Moved here from `MacCastTests`**, which Xcode 27 cannot execute: for a test action it builds
/// every package product as a separate dynamic framework, and the Crypto product's target does its
/// packaging and then touches the framework without ever running a link step, so X509, RemoteCore
/// and the app fail to link in a cascade. Nothing in the app can fix that. Everything in this file
/// is policy that needs no app bundle, no view and no session, which is what lets it run under
/// `swift test` in seconds, with no Xcode involved at all.
///
/// The two tests that genuinely need UIKit are still in `MacCastTests`: they drive a
/// `GestureSurfaceView` and measure what it reports, and there is no honest way to do that without
/// a view. They are the whole of what is left behind.
///
/// `@MainActor`, because everything it tests is, in the app. The app builds with
/// `SWIFT_DEFAULT_ACTOR_ISOLATION = MainActor`, so these types are main-actor types there and the
/// tests were written against that; here they are not, and this says what was already true rather
/// than moving work onto the main actor to satisfy the compiler.
@MainActor
final class MacCastPolicyTests: XCTestCase {

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
        // What the settings panel draws under "Manual". `auto` belongs to the mode picker above
        // it, and a preset that appeared in both lists would be two controls for one setting.
        XCTAssertEqual(StreamQuality.manualCases, [.low, .medium, .high])
    }

    func testTakingTheRateOverByHandStartsWhereAutomaticHadIt() {
        // ``SessionModel/setAutomaticQuality(_:)`` hands the policy's current tier to the manual
        // picker on the first switch. That is only seamless if a tier and the preset naming it
        // agree on the rate — they are two separate enums that share a number, and the compiler
        // does not connect them, so this is what holds them together.
        for tier in [AutoQualityPolicy.Tier.low, .medium, .high] {
            let preset = StreamQuality(tier)
            XCTAssertEqual(preset.bitrateKbps, tier.bitrateKbps)
        }
    }

    func testEveryQualityPresetSurvivesBeingStoredAndReadBack() {
        // The stored preference is a `rawValue` in `UserDefaults`, so a preset that did not
        // round-trip would come back as something else on the next launch — and the failure is
        // silent, because `storedQuality` decodes a token it cannot read as "nothing stored".
        for preset in StreamQuality.allCases {
            XCTAssertEqual(StreamQuality(rawValue: preset.rawValue), preset)
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
        for preset in StreamQuality.allCases {
            XCTAssertNil(StreamQuality(rawValue: preset.chipTitle))
        }
        XCTAssertNil(StreamQuality(rawValue: "Med"))
        XCTAssertNil(StreamQuality(rawValue: ""))
    }

    func testTheChipStillSpellsTheFourWordsItAlwaysDid() {
        // The rename of `rawValue` to `chipTitle` is invisible on screen or it is a bug: these
        // are the four strings the speed chip printed before it, and it prints them still.
        XCTAssertEqual(StreamQuality.auto.chipTitle, "Auto")
        XCTAssertEqual(StreamQuality.low.chipTitle, "Low")
        XCTAssertEqual(StreamQuality.medium.chipTitle, "Med")
        XCTAssertEqual(StreamQuality.high.chipTitle, "High")
    }

    func testTheQualityMenuNamesTheRateItIsOffering() {
        // The whole reason the menu exists in two places rather than one: "Low" names a rung on
        // a ladder nobody has been shown, so every option carries what it costs. Both the speed
        // chip and the Settings tab read this, which is what stops them describing the same four
        // presets differently.
        //
        // **All four are written out rather than checked with `contains`.** The blanket version of
        // this, that each menu title contains the preset's own ``StreamQuality/title``, is false
        // for `auto`, whose menu entry says what it follows rather than repeating "Automatic", and
        // it was the first thing this file reported once it could be run at all. The four strings
        // are what the menu actually draws, which is the thing worth pinning anyway.
        XCTAssertEqual(StreamQuality.auto.menuTitle, "Auto, follows the network")
        XCTAssertEqual(StreamQuality.low.menuTitle, "Low, 2 Mbps")
        XCTAssertEqual(StreamQuality.medium.menuTitle, "Medium, 8 Mbps")
        XCTAssertEqual(StreamQuality.high.menuTitle, "High, 20 Mbps")

        // And each one still names its preset in one spelling or the other, so no option is a bare
        // rate with nothing saying which preset it is.
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

    /// Reads one of the three attachments from the level the renderer actually reads it at.
    ///
    /// **Sample level, not buffer level.** `CMGetAttachment` reads the buffer-level bearer, and
    /// these three keys are set on the sample attachment dictionary instead, which is the whole
    /// point of the comment in ``VideoSampleBuffer/make(_:format:)``, because
    /// `AVSampleBufferVideoRenderer` reads them there and a key set at the wrong level is silently
    /// ignored. This helper asked `CMGetAttachment`, so it answered `nil` for all three and every
    /// assertion below compared `nil` against the expected value. The tests looked like they were
    /// checking the picture's decode behaviour and were checking nothing at all.
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

    /// The case this distinction exists for, and the common one. A config comes down the wire
    /// every time the picture moves between the direct channel and the control channel, every
    /// time the video connection re-attaches after a drop, and every time the encoder is rebuilt:
    /// all of them the same source at the same size. A phone that read each of those as a
    /// source change would jump the user's picture for reasons that have nothing to do with what
    /// is on it.
    func testTheSameStreamDescribedAgainIsNotANewPicture() {
        XCTAssertEqual(
            picture("display:1", 3024, 1964).change(to: picture("display:1", 3024, 1964)),
            .unchanged
        )
    }

    /// The same window, resized by whoever is at the Mac. The magnification is a multiple of the
    /// fit, so it still means what it meant; the screen keeps it and re-fits the offset instead.
    func testAResizedWindowKeepsItsMagnification() {
        XCTAssertEqual(
            picture("window:7", 580, 384, movesOnItsOwn: true)
                .change(to: picture("window:7", 902, 640, movesOnItsOwn: true)),
            .resized
        )
    }

    /// A display's surface is fixed for the life of a stream, so a new size for one is not a
    /// resize: it is a different display, or the same display at a new mode, and the rectangle
    /// the old pan was measured against is gone either way.
    func testADisplayAtANewSizeIsNotThePictureTheZoomWasChosenFor() {
        XCTAssertEqual(
            picture("display:1", 3024, 1964).change(to: picture("display:1", 1512, 982)),
            .replaced
        )
    }

    /// Two identical monitors are why the size is not the identity. The picture looks the same
    /// shape and is somewhere else entirely, and the zoom belongs to the one it was chosen over.
    func testASwitchBetweenTwoSourcesOfTheSameSizeIsStillASwitch() {
        XCTAssertEqual(
            picture("display:1", 2560, 1440).change(to: picture("display:2", 2560, 1440)),
            .replaced
        )
    }

    /// A picture described before the catalogue arrived is nameless, and the same picture
    /// described again after it is the name catching up rather than a switch. Every session
    /// starts in this state, and reading it as a change would reset a zoom the user had just set.
    func testAPictureThatEarnsItsNameIsNotASourceChange() {
        XCTAssertEqual(
            picture(nil, 580, 384, movesOnItsOwn: true)
                .change(to: picture("window:7", 580, 384, movesOnItsOwn: true)),
            .unchanged
        )
    }

    /// The catalogue is the only thing in a session that says what a source is, so a source with
    /// no entry behind it stays unknown, and unknown is read as free to move. That direction is
    /// the deliberate one: keeping a magnification that no longer fits costs one pinch, and
    /// throwing one away costs the user the place they were reading.
    func testASourceWithNoCatalogueEntryIsOneWeCannotKnowIsFixed() {
        let display = CaptureSourceDescriptor(
            kind: .display,
            title: "Built-in Display",
            source: .display(1),
            pixelSize: CGSize(width: 3024, height: 1964)
        )
        let catalog = CaptureCatalog(displays: [display])

        // No entry behind the source the phone believes it is watching, so nothing can be said
        // about whether it moves on its own, and unknown is read as free to move.
        XCTAssertTrue(PictureIdentity.forStream(
            config(580, 384), activeSourceID: "window:99", catalog: catalog
        ).contentMovesOnItsOwn)

        // And the display that *is* in the catalogue: a fixed surface, so a new size for it is a
        // different picture rather than a resize.
        XCTAssertFalse(PictureIdentity.forStream(
            config(3024, 1964), activeSourceID: display.id, catalog: catalog
        ).contentMovesOnItsOwn)
    }

    /// A picture of a source with a fixed size, which is the default for these tests: a display
    /// changes size only when what is being captured has changed underneath the zoom.
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

    private func config(_ width: Int, _ height: Int) -> VideoStreamConfig {
        VideoStreamConfig(
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

    // MARK: - Pinch and pan arbitration

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

    // MARK: - The scroll wheel

    func testANotchIsAFixedAmountOfTravelAndOfDocument() {
        var wheel = ScrollWheelState()

        // Twelve points of finger travel is one notch in one sample, and one notch in twelve: the
        // quantum is what was asked for, not a sum of however the drag happened to arrive.
        XCTAssertEqual(wheel.roll(points: ScrollNotch.travel), 1)
        for _ in 0..<11 { XCTAssertEqual(wheel.roll(points: 1), 0) }
        XCTAssertEqual(wheel.delivered, 1)
        XCTAssertEqual(wheel.roll(points: 1), 1)
        XCTAssertEqual(wheel.delivered, 2)

        // Twenty-four pixels a notch, which is about a line of the Mac's text.
        XCTAssertEqual(ScrollNotch.pixels, 24)

        // The rim runs ahead of the Mac by the part of a notch that has not been sent: that is
        // what lets it turn smoothly under the finger while the Mac gets whole lines.
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

        // Past a notch and back: the wheel is where it was and the Mac was never told anything.
        XCTAssertEqual(wheel.roll(points: ScrollNotch.travel + 3), 1)
        XCTAssertEqual(wheel.roll(points: -ScrollNotch.travel - 3), -1)
        XCTAssertEqual(wheel.delivered, 0)
    }

    func testTheWheelSeatsItselfSoAnArrowAlwaysDeliversANotch() {
        var wheel = ScrollWheelState()

        // Let go most of the way into a notch, and the spring finishes it — forward, because it
        // was pushed past halfway. At most half a notch of scroll either way, which is the price
        // of the wheel always resting somewhere a whole notch is.
        XCTAssertEqual(wheel.roll(points: ScrollNotch.travel / 2 + 1), 0)
        XCTAssertEqual(wheel.seat(), 1)
        XCTAssertEqual(wheel.phase, 1, accuracy: 0.0001)

        // And short of halfway, it springs back rather than delivering a line the hand did not
        // finish asking for.
        XCTAssertEqual(wheel.roll(points: ScrollNotch.travel / 2 - 1), 0)
        XCTAssertEqual(wheel.seat(), 0)
        XCTAssertEqual(wheel.phase, 1, accuracy: 0.0001)

        // Seated, so an arrow is exactly one notch — the finest step the control has, and the one
        // that needs no aim.
        XCTAssertEqual(wheel.roll(notches: -1), -1)
        XCTAssertEqual(wheel.delivered, 0)
    }

    func testAFlickCarriesAPageAndThenStops() {
        // A hard flick is capped rather than taken at its word: a phone flick is easily a thousand
        // points a second, and at twelve points to the notch that is eighty notches before any
        // coasting even starts.
        let launch = WheelSpin.launch(pointsPerSecond: 5_000)
        XCTAssertEqual(launch, WheelSpin.launchLimit)

        // At the cap the coast is worth about a page — forty-one notches at twenty-four pixels is
        // nine hundred and ninety-five — and it ends, which is the whole reason the stalling rate
        // and the decay are the pair they are: the rate at the end of the duration *is* the
        // stalling rate.
        XCTAssertEqual(WheelSpin.travel(launch) * ScrollNotch.pixels, 995, accuracy: 15)
        XCTAssertEqual(WheelSpin.rate(launch, after: WheelSpin.duration(launch)), WheelSpin.stalling, accuracy: 0.001)

        // A gentle drag does not coast at all: the wheel has to be turning to keep turning, which
        // is what stops a careful scroll from ending in an unasked-for lurch.
        let slow = WheelSpin.launch(pointsPerSecond: 10)
        XCTAssertEqual(slow, 10 / ScrollNotch.travel, accuracy: 0.0001)
        XCTAssertEqual(WheelSpin.duration(slow), 0)
    }

    // MARK: - Session awareness

    /// **The rule that stops two Macs overwriting each other's banner.** An identifier fixed per
    /// kind is right for one Mac and wrong for several: two Macs ending a session at the same
    /// moment produce one banner about one of them, and the one that loses is whichever the system
    /// saw first — which for a pairing code is a pairing the user never gets to finish.
    func testTwoMacsBannersDoNotReplaceEachOther() {
        let one = SessionAwareness.Notification(
            kind: .awaitingPairingCode, title: "Pairing with Studio", body: "…", hostID: "AAAAAA"
        )
        let other = SessionAwareness.Notification(
            kind: .awaitingPairingCode, title: "Pairing with Attic", body: "…", hostID: "BBBBBB"
        )

        XCTAssertNotEqual(one.identifier, other.identifier)
    }

    /// The rest of the rule is unchanged: the same kind and the same Mac still replaces itself, so
    /// a session that passes through a phase twice does not stack two banners about one thing.
    func testTheSameMacAndKindStillReplacesItself() {
        let first = SessionAwareness.Notification(
            kind: .awaitingPairingCode, title: "Pairing with Studio", body: "…", hostID: "AAAAAA"
        )
        let second = SessionAwareness.Notification(
            kind: .awaitingPairingCode, title: "Pairing with Studio", body: "…", hostID: "AAAAAA"
        )

        XCTAssertEqual(first.identifier, second.identifier)
    }

    /// A caller with no Mac in hand is no worse off than before: the identifier falls back to the
    /// kind's own name, which is what every call site used to get.
    func testABannerWithNoMacKeepsTheKindIdentifier() {
        let notification = SessionAwareness.Notification(
            kind: .connected, title: "Connected", body: "…"
        )

        XCTAssertEqual(notification.identifier, SessionAwareness.Kind.connected.identifier)
    }

    /// And the rule threads it through, rather than leaving it to the notifier to remember.
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

    // MARK: - The stored preference

    /// A defaults store of this test's own, so the rule can be exercised without writing to the
    /// real one. A test that has to save and restore `UserDefaults.standard` is a test that fails
    /// when another one runs beside it.
    private func scratchDefaults(_ name: String = #function) throws -> UserDefaults {
        let suite = "MacCastKitTests.\(name)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defaults.removePersistentDomain(forName: suite)
        addTeardownBlock { defaults.removePersistentDomain(forName: suite) }
        return defaults
    }

    /// ``StreamQuality/stored(in:)`` is the read side of the preference, and it has to answer for a
    /// key that was never written, which is every install that predates the setting.
    ///
    /// Automatic is the behaviour the app had before the setting existed, so it is the only honest
    /// default. A token from a future version answers the same way rather than reading as a choice
    /// somebody made.
    func testAnUnrecognisedQualityFallsBackToAutomatic() throws {
        let defaults = try scratchDefaults()

        XCTAssertEqual(StreamQuality.stored(in: defaults), .auto)

        defaults.set("ultra", forKey: PreferenceKeys.streamQuality)
        XCTAssertEqual(StreamQuality.stored(in: defaults), .auto)

        defaults.set(StreamQuality.medium.rawValue, forKey: PreferenceKeys.streamQuality)
        XCTAssertEqual(StreamQuality.stored(in: defaults), .medium)
    }

    /// The half of the feature that is easy to leave out, and was.
    ///
    /// The Settings tab writes the preference and cannot reach the model. The model is built once
    /// for the life of the process, and that tab is unreachable while a session runs, which is why
    /// it writes a preference at all. So its copy of the preset is stale from launch, and the
    /// arrival is the only moment the two can be brought back together. What arrives is decided
    /// here, from the store rather than from anything the process is holding.
    func testASessionStartsAtWhatTheSettingsTabStored() throws {
        let defaults = try scratchDefaults()

        defaults.set(StreamQuality.high.rawValue, forKey: PreferenceKeys.streamQuality)
        XCTAssertEqual(StreamQuality.stored(in: defaults), .high)
        XCTAssertEqual(StreamQuality.storedManualLevel(in: defaults), .high)

        // And the automatic case, which must come back automatic and must not invent a manual
        // level to return to: there is none, and the policy's tier is what stands in.
        defaults.set(StreamQuality.auto.rawValue, forKey: PreferenceKeys.streamQuality)
        XCTAssertEqual(StreamQuality.stored(in: defaults), .auto)
        XCTAssertNil(StreamQuality.storedManualLevel(in: defaults))
    }
}

// MARK: - Subscription offers

/// When the app asks the user to subscribe, and how often.
///
/// This is the part that can be wrong in a way nobody notices. An offer that never arrives costs a
/// sale silently, and one that arrives twice is a nag the user has no switch for. Both look exactly
/// like the feature working, from inside the app, until somebody complains. So the decision is
/// tested here rather than left to the screen that carries it.
///
/// **The decision and not the showing.** Holding the answer for half a second and then spending it
/// is an effect on a running app; what is decided, and which of the two memories it spends, is the
/// whole of the rule and is what these pin.
@MainActor
final class SessionOfferPolicyTests: XCTestCase {
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

    /// Everything the rule reads, with the ordinary answer for each: a metered plan, nothing on
    /// screen, nobody asked, and an allowance so far from low that it is not in play.
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

    /// A window whose free relay allowance is nearly gone: three of the plan's fifteen minutes
    /// left, which is under the quarter that ``SessionOfferPolicy/lowRelayAllowanceFraction``
    /// calls running low.
    ///
    /// Read off ``RelayPlan`` rather than typed in, because this number has already moved once and
    /// a fixture that has to be remembered is a fixture that will be missed.
    private var nearlySpent: Double { 180.0 / (RelayPlan.free.allowanceSeconds ?? 1) }

    /// The connect that was a mistake, and the one that dropped on arrival. Both reach this with a
    /// record, because both reached `.ready`, which is what the floor is for.
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

    /// Somebody who has never finished a session is hearing about the relay for the first time and
    /// ought to get the whole case rather than the running-low version of it, even if their
    /// allowance happens to be low already. The two offers are ordered, not ranked.
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

    /// Free is fifteen minutes a day, so twelve minutes spent leaves three, under the quarter
    /// that ``SessionOfferPolicy/lowRelayAllowanceFraction`` calls running low.
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

    /// Spent and nearly spent are different sentences, and at zero only one of them is true.
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

    /// A session that spent no relay, on a day whose relay is nearly gone. The meter has not moved
    /// because of this session, and the Sessions tab is already saying the same figure.
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

        // And the next window is a new asking: the offer is remembered per window, not forever.
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

    /// The paywall the user opened themselves is already on screen. There is one `paywallReason`,
    /// and replacing it would rewrite the screen being read.
    func testAnOpenPaywallIsNotOverwrittenByAnOffer() {
        XCTAssertNil(SessionOfferPolicy.decision(
            after: record(path: .lan, duration: 90),
            state: state(hasPaywallOpen: true)
        ))
    }

    /// An offer that is still waiting out its half-second is on its way to that same screen, so a
    /// second one arriving behind it is the same rewrite a moment later.
    func testAnOfferAlreadyInFlightIsNotReplacedByASecond() {
        XCTAssertNil(SessionOfferPolicy.decision(
            after: record(path: .lan, duration: 90),
            state: state(hasPendingOffer: true)
        ))
    }

    /// A plan with no allowance has nothing to be low on, and an unmetered subscriber has already
    /// bought the thing this would be selling.
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

/// One finished session, as it is written down and read back.
@MainActor
final class ClientSessionRecordTests: XCTestCase {
    private func encodedWithoutDirectPath() -> Data {
        // Exactly what this app wrote before `usedDirectPath` existed: every key the type had,
        // and no key for the new one.
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

    /// **The record has to survive a field being added to it.** These are written to
    /// `UserDefaults` and read back on the next launch, so a decoder that requires every key would
    /// throw on the first launch after an update and the whole history would be silently dropped —
    /// thirty sessions lost to make room for one flag.
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

    /// And the new field round-trips, or filing it would be pointless.
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
}
