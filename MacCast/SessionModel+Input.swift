import MacCastKit
import RemoteCore
import SwiftUI
import UIKit

/// What a gesture or a keystroke turns into on the wire. An extension on the model rather than a type
/// of its own, because this state is the model's.
extension SessionModel {
    /// The only path input takes: everything goes through the session's coalescer, so the rules about
    /// what may be merged and what must never be dropped live in one place rather than in each gesture
    /// recogniser.
    /// The speeds the joystick's double tap steps through, and back to the start.
    ///
    /// Halves rather than whole numbers for the first step, because the useful range is narrow: 1× is
    /// right for aiming at a button and too slow for crossing a 5K display, and the first thing anyone
    /// wants is a little more, not double.
    static let pointerSpeeds: [Double] = [1, 1.5, 2, 2.5, 3]

    func cyclePointerSpeed() {
        let speeds = Self.pointerSpeeds
        // `firstIndex` on the value rather than a stored index, so a speed that is not in the list, an
        // older build's setting or a hand-edited default, restarts the cycle instead of trapping on an
        // out-of-range index.
        let index = speeds.firstIndex(of: pointerSpeed) ?? 0
        pointerSpeed = speeds[(index + 1) % speeds.count]
        UserDefaults.standard.set(pointerSpeed, forKey: PreferenceKeys.pointerSpeed)
    }

    /// How the speed is written: "1×", "1.5×", "2×".
    var pointerSpeedLabel: String {
        pointerSpeed == pointerSpeed.rounded()
            ? "\(Int(pointerSpeed))"
            : String(format: "%.1f", pointerSpeed)
    }

    func send(_ command: RemoteCommand) {
        // Two different rules: observe mode is the user saying they do not want the Mac touched at all,
        // so it means the whole of `isUserInput`, while a mosaic only means it does not know which window
        // a point landed in, so it means the part carrying a point or a keystroke and not switching
        // Space. See ``RemoteCommand/isBlockedByMosaic``.
        guard !isObserving || !command.isUserInput else { return }
        guard !isShowingMosaic || !command.isBlockedByMosaic else { return }
        session?.send(command)
    }

    func setObserveOnly(_ enabled: Bool) {
        guard enabled != isObserving else { return }
        if enabled { releaseLatchedModifiers() }
        isObserving = enabled
    }

    /// Lets go of any modifier the Mac still believes is held.
    ///
    /// Every mode that stops the user's keys reaching the Mac has to call this: a modifier latched before
    /// the mode was entered cannot be released by the button that would release it, since that button's
    /// key-up is exactly what the mode refuses to send. Clearing only the phone's visual state leaves
    /// Command or Shift held on the far end, which the next session's typing inherits.
    private func releaseLatchedModifiers() {
        let held: [(Modifiers, UInt16)] = [
            (.command, 55),
            (.shift, 56),
            (.option, 58),
            (.control, 59),
        ]
        for (modifier, keyCode) in held where latchedModifiers.contains(modifier) {
            session?.send(.keyUp(keyCode: keyCode, modifiers: []))
        }
        latchedModifiers = []
    }

    func setPrivacyMode(_ enabled: Bool) {
        guard phase == .ready else { return }
        privacyModeEnabled = enabled
        send(.setPrivacyMode(enabled: enabled))
    }

    func lockMac() {
        guard phase == .ready else { return }
        send(.lockScreen)
    }

    func selectSource(_ descriptor: CaptureSourceDescriptor) {
        // Through the source rather than beside it: a descriptor's id *is* its source's stable id, and
        // this must not send the command without recording the choice. See ``selectSource(_:)`` for what
        // happens when those two come apart.
        selectSource(descriptor.source)
    }

    /// The same, for a caller holding a ``CaptureSource`` rather than the descriptor it was listed
    /// under.
    ///
    /// Recording the choice is the point: `activeSourceID` is what callers compare against before
    /// deciding whether a switch is needed, so a caller that sends `setCaptureSource` itself leaves the
    /// record describing a screen the video is no longer on, and the next comparison reads as "already
    /// there" and sends nothing. The result is a session that follows the desktops panel onto the second
    /// display and then refuses to come back.
    func selectSource(_ source: CaptureSource) {
        PictureTrace.write("select \(source.stableID) mosaic=\(source.isMosaic) choices=\(mosaicChoices.count)")
        activeSourceID = source.stableID
        // Recorded from the source rather than the call site, so no door into this can miss it. See
        // ``MacSession/isAskingForMosaic``.
        activeSession?.isAskingForMosaic = source.isMosaic
        // The ask as it was made: it is what the Mac will build, and the arrangement this end computes
        // later is not. See ``MacSession/askedMosaicLayout``.
        if case .mosaic(let layout) = source {
            activeSession?.askedMosaicLayout = layout
        } else {
            activeSession?.askedMosaicLayout = nil
        }

        // What the user was looking at is what the next connection to this Mac opens on, and this is the
        // only place that can be said: every source the user asks for arrives here, and a save at each of
        // the doors into it is a save one of them can be missing. See ``ChosenSourceStore``.
        //
        // The default a session picks for itself never comes through here, which is the rule: the app
        // choosing the first display is not the user choosing anything. See
        // ``sourceToRestore(hostID:catalog:)``.
        //
        // A mosaic is passed over: an arrangement has a store that understands it, and leaving the
        // remembered single source untouched is what lets a Mac whose arrangement has since lost a window
        // fall back to what the user was last looking at.
        if !source.isMosaic, let hostID = currentHostID {
            ChosenSourceStore.save(source, hostID: hostID)
        }

        // A remembered arrangement lasts exactly as long as the user is inside it: selecting one of its
        // tiles keeps it and leaves the back control on offer, while selecting anything else is leaving it
        // behind. The mosaic itself keeps it by the same rule.
        if !source.isMosaic,
           !mosaicChoices.contains(where: { $0.source == source }) {
            mosaicChoices = []
        }

        // **Closed before the ask goes out, not after the answer arrives.** A frame can beat the
        // config it belongs to (they travel on different connections), and a frame with no config in
        // front of it is drawn at the *previous* picture's magnification: a window magnified by the
        // zoom that had filled the screen with a tile of it, for a frame or two, on some taps and
        // not others. The gate holds what arrives in the meantime and hands it over once the
        // transform that belongs to it has been written. See ``MacSession/changeGate``.
        activeSession?.changeGate.hold()
        session?.selectCaptureSource(source)
    }

    // MARK: - The mosaic

    /// Draws several of the Mac's sources into one picture and shows it.
    ///
    /// The canvas is the phone's own screen in pixels: each tile gets a fraction of it, so a smaller
    /// canvas would make every tile soft before the encoder ever saw it, and the Mac trims one larger
    /// than it will build. The rectangles come from ``MosaicGrid``.
    func showMosaic(_ sources: [CaptureSource]) {
        showMosaic(sources.map { MosaicChoice(source: $0) })
    }

    /// The arrangement the user is coming back to, drawn from the frame it had last time.
    ///
    /// **Called when the movement into it has landed, and that timing is the whole of it.**
    /// Leaving an arrangement and returning to it is a stream torn down and a canvas of tiles built
    /// again on the Mac, measured at about a second and a quarter, and for the whole of it the phone
    /// would show the window that was tapped inside the tile it just shrank into. The last frame
    /// this end had of *that* source is a better answer, and it appears exactly where the movement
    /// has left the window, because it is put up through the same arrival machinery any other
    /// picture is.
    ///
    /// **At the ask instead, and that was wrong.** Asked for at the tap, the canvas was on screen
    /// while the movement meant to carry the window into its tile was still running, which is an
    /// arrangement appearing over the animation rather than after it.
    ///
    /// Only for an arrangement: a display rebuilds in a moment and a window's own stream is a frame
    /// away, so neither has a wait worth covering. See ``VideoRenderer/recalledFrame(for:)``.
    func putUpRecalledPicture() {
        guard let asked = activeSession?.askedMosaicLayout,
              activeSession?.isAskingForMosaic == true
        else { return }
        let source = CaptureSource.mosaic(asked)
        guard source.stableID == activeSourceID,
              let recalled = renderer.recalledFrame(for: source.stableID)
        else { return }
        activeSession?.picture = PictureIdentity(
            sourceID: source.stableID,
            pixelSize: recalled.pixelSize,
            contentMovesOnItsOwn: source.contentMovesOnItsOwn
        )
        renderer.showRecalledFrame(recalled.sample, pixelSize: recalled.pixelSize)
    }

    /// The same, keeping whatever sizes the tiles already had: adding or removing a window is not a reason
    /// to reset the arrangement's shape.
    ///
    /// - Parameter remembering: whether this ask is the user arranging something, or the app putting back
    ///   what they arranged. A restore is the second, and it must not write what it thinned: it asks with an
    ///   arrangement filtered by what the catalogue can see, and a window that a catalogue merely failed to
    ///   list would then be gone from the store as well as from the picture.
    func showMosaic(_ choices: [MosaicChoice], remembering: Bool = true) {
        PictureTrace.write("showMosaic tiles=\(choices.count) remembering=\(remembering) viewport=\(PictureTrace.short(mosaicViewport))")
        // **Shaped by the choices being asked for, not by the ones already on screen.** The canvas's
        // aspect comes from how wide the arrangement's windows are, and reading that off the session
        // meant a restore, which runs before the new choices are stored, shaped its canvas from the
        // fallback instead. The same arrangement therefore came back a different shape from the one
        // it was built at. See ``MacSession/tileAspect(for:)``.
        guard let layout = MosaicGrid.layout(
            choices: choices,
            viewport: mosaicViewport,
            tileAspect: activeSession?.tileAspect(for: choices) ?? MosaicGrid.windowAspect
        ) else {
            return
        }
        PictureTrace.write("  asked canvas=\(PictureTrace.short(layout.canvas))")
        // Anything held down on the Mac is let go first: what is on screen is about to be a picture with
        // no input at all, and a modifier latched before that is one nothing here can release.
        releaseLatchedModifiers()
        // A tile that opened nothing last time gets another try here, because this is the user asking for
        // the arrangement rather than the app re-using the one it has. See
        // ``MacSession/sourcesThatOpenedNothing``.
        sourcesThatOpenedNothing = []
        mosaicChoices = choices
        // Remembered as the *choices*, not as the rectangles being sent to the Mac: an arrangement is a
        // place the user returns to, and the windows it was made of is what survives a restart and a
        // rotation. See ``MosaicArrangementStore``.
        if remembering, let hostID = currentHostID {
            MosaicArrangementStore.save(choices, hostID: hostID)
        }
        selectSource(.mosaic(layout))
    }

    /// The arrangement this Mac was last left in, thinned to what it still has.
    ///
    /// Asked when the catalogue arrives, the first moment anything knows which of the remembered windows
    /// still exist: a window ID outlives neither a restart nor a quit. Fewer than two survivors is nothing,
    /// the same rule that stops a one-tile canvas being a mosaic at all.
    ///
    /// A pure lookup rather than something that sends: the caller is deciding *instead of* the default
    /// source, and a function that both answered and acted could not be used that way.
    ///
    /// An arrangement the plan no longer includes is not restored, which is the same rule as the
    /// padlock on the panel: a subscription that lapsed is not a subscription, and a reconnection is
    /// not a way round the gate. See ``PlanCapability/mosaic``.
    func mosaicToRestore(hostID: String?, catalog: CaptureCatalog?) -> [MosaicChoice] {
        guard let hostID, storeManager.access.includes(.mosaic) else { return [] }
        return MosaicArrangement.restored(
            MosaicArrangementStore.load(hostID: hostID),
            into: catalog
        )
    }

    /// The one source this Mac was last left on, if the Mac still has it.
    ///
    /// Asked at the same moment as the arrangement and answered second: an arrangement is what the user
    /// built, while a single source is only what they were looking at, so the arrangement wins where both
    /// are remembered. What is left when both have gone is the first display. See ``ChosenSource``.
    ///
    /// **A virtual display is not restored on a plan without one.** It is the only source here that a
    /// plan decides, and the row it is picked from is locked on that plan: restoring it anyway would
    /// be a padlock a reconnection walks around. See ``PlanCapability/virtualDisplays``.
    func sourceToRestore(hostID: String?, catalog: CaptureCatalog?) -> CaptureSource? {
        guard let hostID, let source = ChosenSource.restored(
            ChosenSourceStore.load(hostID: hostID),
            into: catalog
        ) else { return nil }
        if let descriptor = catalog?.descriptor(for: source),
           descriptor.isVirtualDisplay,
           !storeManager.access.includes(.virtualDisplays) {
            return nil
        }
        return source
    }

    /// Gives one tile more or less room, cycling through the sizes the control offers.
    ///
    /// A weight rather than a size: the arithmetic decides what "this one matters more" means on a canvas
    /// of this shape, which is the only version that survives a seventh window being added afterwards.
    /// See ``MosaicGrid/rects(weights:)``.
    func stepMosaicTileSize(at index: Int, by step: Int) {
        guard mosaicChoices.indices.contains(index) else { return }
        let current = mosaicChoices[index].weight
        let next = min(max(current + step, MosaicChoice.minimumWeight), MosaicChoice.maximumWeight)
        guard next != current else { return }

        var choices = mosaicChoices
        choices[index].weight = next
        showMosaic(choices)
    }

    /// Selects one of the tiles, which is how the arrangement is left.
    ///
    /// An ordinary source switch apart from what is kept: from that moment the session is the session it
    /// always was, at full resolution with the whole input path and the adaptive quality, and the tile can
    /// be given back because the arrangement is retained.
    ///
    /// A window rather than a slot, and the turn is the screen's to make: the tap resolved an index against
    /// the arrangement it was drawn for, and the Mac's answer since a reorder describes the arrangement the
    /// user has just left, so resolving the index here would open the window in that slot rather than the
    /// one under the finger. See ``RemoteScreen/shownMosaicLayout``.
    func focusMosaicTile(_ source: CaptureSource) {
        selectSource(source)
    }

    /// What the arrangement is made of, in the order it is laid out. See
    /// ``MacSession/mosaicChoices``.
    var mosaicChoicesList: [MosaicChoice] { mosaicChoices }

    /// Moves a tile within the arrangement.
    ///
    /// The order is the arrangement: the grid is filled in reading order, so moving a source up the list
    /// moves it up the picture, and there is no second thing to keep in step.
    func moveMosaicTile(from source: Int, to destination: Int) {
        guard mosaicChoices.indices.contains(source),
              mosaicChoices.indices.contains(destination),
              source != destination
        else { return }
        // The whole choice moves, size and all: moving a window in the picture is moving the thing the user
        // arranged, not just its place in a list of names.
        var choices = mosaicChoices
        let moved = choices.remove(at: source)
        choices.insert(moved, at: destination)
        showMosaic(choices)
    }

    /// Takes one window out of the arrangement and redraws the rest.
    func removeMosaicTile(at index: Int) {
        guard mosaicChoices.indices.contains(index) else { return }
        var choices = mosaicChoices
        choices.remove(at: index)

        // A mosaic of one is not a mosaic: taking the second-to-last tile away leaves one window on screen,
        // and the honest thing to show is that window on its own, an ordinary source switch with the input
        // and the sharpness that come with it.
        guard choices.count > 1 else {
            // And the arrangement goes with it: ``selectSource(_:)`` drops an arrangement only for a source
            // that is *not* one of its tiles, and this one is, so clearing the store is not enough on its
            // own. Without this the Mac shows the window while this end still describes a mosaic.
            if let hostID = currentHostID {
                MosaicArrangementStore.save([], hostID: hostID)
            }
            mosaicChoices = []
            if let only = choices.first { selectSource(only.source) }
            return
        }
        showMosaic(choices)
    }

    /// Asks the Mac for the arrangement again, at the shape the phone is now held at.
    ///
    /// For the rotation, the one thing that changes a layout's identifier without anybody choosing
    /// anything: the canvas is built for the arrangement and the screen, so turning the phone makes the
    /// layout different and gives it a new identifier, while the source the Mac is capturing keeps the old
    /// one, which this end reads as "not showing a mosaic" and the tile borders vanish. See
    /// ``MacSession/isAskingForMosaic``.
    ///
    /// Asked once the phone has stopped moving, not while it is starting to: the viewport changes the
    /// instant the rotation begins, so asking immediately puts the Mac's answer, a different canvas and a
    /// decoder flush before its first frame, inside the system's own rotation animation. The wait is also
    /// a debounce, for a rotation reported in two steps.
    ///
    /// Nothing happens unless an arrangement is what the user asked for: a session on a single window with
    /// a remembered arrangement behind it must not have a mosaic put back in front of them because they
    /// turned the phone.
    func refreshMosaicForViewport() {
        mosaicViewportTask?.cancel()
        mosaicViewportTask = Task { @MainActor [weak self] in
            // A settle rather than a wait for a measurement: the canvas can be built the moment the
            // interface knows which way it is going, at the start of the movement, so the only question is
            // how much of the movement to overlap. A fifth of a second plus the Mac's own hundred
            // milliseconds puts the picture's movement at the end of the screen's, which is where a turn
            // should hand over. See ``MacSession/mosaicViewport``.
            try? await Task.sleep(for: .milliseconds(200))
            guard !Task.isCancelled, let self else { return }
            guard activeSession?.isAskingForMosaic == true, !mosaicChoicesList.isEmpty else { return }
            showMosaic(mosaicChoicesList)
        }
    }

    /// The pending re-ask, so a rotation that is still settling can replace it rather than queue
    /// behind it. See ``refreshMosaicForViewport()``.
    private var mosaicViewportTask: Task<Void, Never>? {
        get { activeSession?.mosaicViewportTask }
        set { activeSession?.mosaicViewportTask = newValue }
    }

    /// The pending gap check, so a catalogue that changes twice in a row is looked at once and
    /// then. See ``scheduleMosaicGapCheck()``.
    private var mosaicGapTask: Task<Void, Never>? {
        get { activeSession?.mosaicGapTask }
        set { activeSession?.mosaicGapTask = newValue }
    }

    /// The tiles this session has asked for and got nothing back from. See
    /// ``MacSession/sourcesThatOpenedNothing``.
    var sourcesThatOpenedNothing: Set<String> {
        get { activeSession?.sourcesThatOpenedNothing ?? [] }
        set { activeSession?.sourcesThatOpenedNothing = newValue }
    }

    /// The pending wait for a tapped tile to open. See ``RemoteScreen/watchTileOpening(_:)``.
    var tileOpeningWatch: Task<Void, Never>? {
        get { activeSession?.tileOpeningWatch }
        set { activeSession?.tileOpeningWatch = newValue }
    }

    /// Waits a moment, then closes the arrangement's gaps. See ``dropClosedMosaicTiles()``.
    ///
    /// The grace is for a catalogue that is wrong more often than it looks: one arrives for a launch, a
    /// quit, a change of Spaces and a change of screen, and it is rebuilt from a fresh enumeration each
    /// time, so a window can be missing from one and back in the next. An arrangement thinned on the first
    /// would lose the tile, re-ask the Mac for a smaller canvas and then have to put it back.
    func scheduleMosaicGapCheck() {
        mosaicGapTask?.cancel()
        mosaicGapTask = Task { @MainActor [weak self] in
            try? await Task.sleep(for: .seconds(2))
            guard !Task.isCancelled, let self else { return }
            self.dropClosedMosaicTiles()
        }
    }

    /// Takes the windows that have gone out of the arrangement, and gives their space to the rest.
    ///
    /// Thinned rather than discarded, so the order and the sizes survive: a tile with a card in it is a
    /// window nobody can open and room nobody is using, and the windows that remain keep saying what the
    /// user arranged.
    ///
    /// Re-asked only when the arrangement is what is showing, since that is the only case where freeing the
    /// space is something the user can see; one thinned while a tile of it is open is kept for the way back.
    /// Fewer than two survivors is no arrangement at all. See
    /// ``MacSession/mosaicToRestore(hostID:catalog:)``.
    func dropClosedMosaicTiles() {
        guard !mosaicChoices.isEmpty, let catalog = activeSession?.catalog else { return }
        PictureTrace.write("gap check of \(mosaicChoices.count) tiles")

        let living = mosaicChoices.filter { catalog.descriptor(for: $0.source) != nil }
        // Nothing is thrown away: fewer than two survivors is not an arrangement to redraw, and it is not
        // one to forget either, because a catalogue can be missing a window for reasons that have nothing to
        // do with the window. What is left alone is the arrangement the user built, waiting for the windows
        // to come back. See ``scheduleMosaicGapCheck()``.
        guard living.count > 1, living.count != mosaicChoices.count else { return }

        if isShowingMosaic || isAskingForMosaic {
            showMosaic(living)
        } else {
            mosaicChoices = living
        }
    }

    /// Goes back to the whole arrangement.
    func returnToMosaic() {
        guard let layout = mosaicLayout else { return }
        selectSource(.mosaic(layout))
    }

    func launchApplication(_ descriptor: InstalledApplicationDescriptor) {
        send(.launchApplication(bundleIdentifier: descriptor.bundleIdentifier))
    }

    func setKeyboardMode(_ mode: KeyboardMode) {
        keyboardMode = mode
        UserDefaults.standard.set(mode.rawValue, forKey: PreferenceKeys.keyboardMode)
    }

    /// Latches a modifier on or off.
    ///
    /// Sent as a real modifier key press rather than as flag bits on the next keystroke, because that is
    /// what the host tracks: setting `flags` describes one event and does not release the modifier, so the
    /// window server would go on believing it is held. A latched modifier is also what makes a two-finger
    /// shortcut possible from a touch screen at all, since there is no way to hold ⌘ with one hand and type
    /// with the other on a phone.
    func toggleModifier(_ bit: Modifiers, keyCode: UInt16) {
        let isOn = latchedModifiers.contains(bit)
        if isOn {
            latchedModifiers.remove(bit)
            send(.keyUp(keyCode: keyCode, modifiers: []))
        } else {
            latchedModifiers.insert(bit)
            send(.keyDown(keyCode: keyCode, modifiers: []))
        }
    }

    /// Return, and the typed preview goes with it.
    ///
    /// The preview is the line the Mac has been sent since it was last emptied, and a Return is the point
    /// at which that stops describing anything: the line is committed, and a bar still showing the old text
    /// claims the Mac is holding something it has already taken.
    func pressReturn() {
        typedPreview = ""
        send(.keyDown(keyCode: 36, modifiers: latchedModifiers))
        send(.keyUp(keyCode: 36, modifiers: latchedModifiers))
        // And the keyboard goes with the line. The bar and its field exist only while the keyboard is
        // up, so this is what empties the field from every door into a commit, not only the keyboard's.
        showKeyboard = false
    }

    /// Text from the software keyboard, routed by the current mode.
    func handleTypedText(_ text: String) {
        guard !text.isEmpty else { return }
        // A newline is a Return by another name, delivered as text rather than as a key, so it commits the
        // line for the same reason ``pressReturn()`` does.
        // Bounded far beyond anything the bar can draw: the view already draws one line truncated at the
        // head, so this only has to stop the string growing without limit.
        typedPreview = text.contains(where: \.isNewline)
            ? ""
            : String((typedPreview + text).suffix(400))

        switch keyboardMode {
        case .unicode:
            send(.textInput(text))

        case .keycode:
            // Per character, with the latched modifiers attached, so ⌘-latched typing works. A character
            // with no Mac keycode, an emoji or a CJK glyph, falls back to a text injection rather than
            // being silently swallowed.
            for character in text {
                guard let code = KeycodeMap.macOSKeycode(forCharacter: character) else {
                    send(.textInput(String(character)))
                    continue
                }
                // Uppercase and the shifted symbols are the same key as their unshifted forms, so shift has
                // to ride along or "Hello" arrives as "hello".
                var modifiers = latchedModifiers
                if KeycodeMap.characterNeedsShift(character) { modifiers.insert(.shift) }
                send(.keyDown(keyCode: code, modifiers: modifiers))
                send(.keyUp(keyCode: code, modifiers: modifiers))
            }
        }
    }

    func handleBackspace() {
        typedPreview = String(typedPreview.dropLast())
        // 51 is Delete (backspace) on every Mac layout. Sent in both modes: in Unicode mode there is no text
        // to delete backwards over, so a keycode is the only thing that can express it.
        send(.keyDown(keyCode: 51, modifiers: latchedModifiers))
        send(.keyUp(keyCode: 51, modifiers: latchedModifiers))
    }

    /// A key from a hardware keyboard, in keycode mode.
    func handleHardwareKey(_ usage: UIKeyboardHIDUsage, down: Bool, flags: UIKeyModifierFlags) {
        guard keyboardMode == .keycode,
              let code = KeycodeMap.macOSKeycode(for: usage)
        else { return }
        // The latch rides along here too: a modifier held on the far end has to be in the flags of every
        // event sent while it is held, whichever keyboard the key came from.
        let modifiers = KeycodeMap.modifiers(from: flags).union(latchedModifiers)
        send(down ? .keyDown(keyCode: code, modifiers: modifiers)
                  : .keyUp(keyCode: code, modifiers: modifiers))
    }

    // MARK: - Geometry

    /// Whether the app is choosing the rate, or the person watching is.
    var isAutomaticQuality: Bool {
        activeSession?.isAutomaticQuality ?? (streamQuality == .auto)
    }

    /// The fastest the picture may go on the active session, which is the plan's answer and the
    /// path's. See ``MacSession/videoCeiling``.
    var videoCeiling: AutoQualityPolicy.Tier {
        activeSession?.videoCeiling ?? .high
    }

    /// Switches between the app choosing the rate and the person watching choosing it.
    ///
    /// The one door the Settings tab uses, and that tab is unreachable while a session is running, so the
    /// no-session branch below is not an edge case, it is the case that tab exists for. It writes the
    /// choice down and nothing more; the next session reads it back through ``storedQuality``.
    func setAutomaticQuality(_ automatic: Bool) {
        guard let activeSession else {
            rememberQualityChoice(automatic ? .auto : (lastManualQuality ?? streamQuality))
            return
        }
        activeSession.setAutomaticQuality(automatic)
    }

    /// Sets the preset, tells the active Mac, and remembers it.
    ///
    /// The save is what makes the Settings tab's row and this one the same setting rather than two:
    /// whichever is used, the stored token ends up saying the same thing, so the next session starts where
    /// this one was left. Written even when there is no session to tell.
    func setStreamQuality(_ quality: StreamQuality) {
        guard let activeSession else {
            // No Mac to tell, and nothing to gate either: with no session there is no relay carrying the
            // bytes. The choice is simply remembered for whenever one arrives.
            rememberQualityChoice(quality)
            return
        }
        activeSession.setStreamQuality(quality)
    }

}
