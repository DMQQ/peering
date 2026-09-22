import MacCastKit
import RemoteCore
import SwiftUI
import UIKit

/// What a gesture or a keystroke turns into on the wire.
///
/// An extension on the model rather than a type of its own: this state is the
/// model's, and splitting the *type* would mean either exposing it or copying it.
extension SessionModel {
    /// The only path input takes. Everything goes through the session's coalescer, so the
    /// rules about what may be merged and what must never be dropped live in one place
    /// instead of in each gesture recogniser.
    /// The speeds the joystick's double tap steps through, and back to the start.
    ///
    /// Halves rather than whole numbers for the first step, because the useful range is narrow:
    /// 1× is right for aiming at a button and too slow for crossing a 5K display, and the first
    /// thing anyone wants is a little more, not double.
    static let pointerSpeeds: [Double] = [1, 1.5, 2, 2.5, 3]

    func cyclePointerSpeed() {
        let speeds = Self.pointerSpeeds
        // `firstIndex` on the value rather than a stored index, so a speed that is not in the
        // list — an older build's setting, a hand-edited default — restarts the cycle instead of
        // trapping on an out-of-range index.
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
        // **Two different rules, and they were one.** Observe mode is the user saying they do not
        // want the Mac touched at all, so it means the whole of `isUserInput`. A mosaic only means
        // it does not know which window a point landed in, so it means the part that carries a
        // point or a keystroke, and not switching Space. See ``RemoteCommand/isBlockedByMosaic``.
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
    /// Called by every mode that stops the user's keys reaching the Mac, and it has to be: a
    /// modifier that was latched before the mode was entered cannot be released by the button
    /// that would release it, because that button's key-up is exactly what the mode is refusing
    /// to send. Clearing only the phone's visual state leaves Command or Shift held on the far
    /// end, which the next session's typing then inherits.
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
        // Through the source rather than beside it: a descriptor's id *is* its source's stable
        // id, and the one thing this must not do is send the command without recording the
        // choice. See ``selectSource(_:)`` for what happens when those two come apart.
        selectSource(descriptor.source)
    }

    /// The same, for a caller holding a ``CaptureSource`` rather than the descriptor it was
    /// listed under.
    ///
    /// **Recording the choice is the whole point of this existing.** `activeSourceID` is what
    /// callers compare against before deciding whether a switch is needed, so a caller that
    /// sends `setCaptureSource` itself leaves the record describing a screen the video is no
    /// longer on — and the next comparison then reads as "already there" and sends nothing.
    /// The visible result is a session that will follow the desktops panel onto the second
    /// display and then refuse to come back.
    /// The same, for a caller holding a ``CaptureSource`` rather than the descriptor it was
    /// listed under.
    ///
    /// **Recording the choice is the whole point of this existing.** `activeSourceID` is what
    /// callers compare against before deciding whether a switch is needed, so a caller that
    /// sends `setCaptureSource` itself leaves the record describing a screen the video is no
    /// longer on — and the next comparison then reads as "already there" and sends nothing.
    /// The visible result is a session that will follow the desktops panel onto the second
    /// display and then refuse to come back.
    func selectSource(_ source: CaptureSource) {
        activeSourceID = source.stableID
        // Recorded from the source rather than from the call site, so it cannot be set by one
        // door into this and missed by another. See ``MacSession/isAskingForMosaic``.
        activeSession?.isAskingForMosaic = source.isMosaic

        // **What the user was looking at is what the next connection to this Mac opens on**, and
        // this is the only place that can be said: every source the user asks for arrives here,
        // and a save at each of the doors into it is a save one of them can be missing. See
        // ``ChosenSourceStore``.
        //
        // The default a session picks for itself never comes through here, which is the rule
        // rather than an oversight: the app choosing the first display is not the user choosing
        // anything, so a Mac that was opened, looked at and left remembers nothing and picks a
        // display the same way next time. See ``sourceToRestore(hostID:catalog:)``.
        //
        // A mosaic is passed over. An arrangement has a store that understands it, and a copy of
        // it here would be a second answer to the same question; leaving the remembered single
        // source untouched beside it is what lets a Mac whose arrangement has since lost a window
        // fall back to the one the user was last looking at on its own.
        if !source.isMosaic, let hostID = currentHostID {
            ChosenSourceStore.save(source, hostID: hostID)
        }

        // **A remembered arrangement lasts exactly as long as the user is inside it.** Selecting
        // one of its tiles is how the mosaic is left, so that choice keeps it and the back
        // control stays on offer; selecting anything else is leaving it behind, and a "back to
        // the mosaic" that still appeared an hour and three sources later would be a button that
        // lies about where it goes. The mosaic itself is not a source outside the arrangement,
        // so asking for one again keeps it by the same rule.
        if !source.isMosaic,
           !mosaicChoices.contains(where: { $0.source == source }) {
            mosaicChoices = []
        }

        session?.selectCaptureSource(source)
    }

    // MARK: - The mosaic

    /// Draws several of the Mac's sources into one picture and shows it.
    ///
    /// **The canvas is the phone's own screen**, in pixels: each tile gets a fraction of the
    /// canvas, so a canvas smaller than the display would make every tile soft before the encoder
    /// ever saw it, and the Mac trims one that is larger than it will build. The rectangles come
    /// from ``MosaicGrid``, which is where the whole arrangement is decided.
    func showMosaic(_ sources: [CaptureSource]) {
        showMosaic(sources.map { MosaicChoice(source: $0) })
    }

    /// The same, keeping whatever sizes the tiles already had: adding or removing a window is not
    /// a reason to reset the arrangement's shape.
    func showMosaic(_ choices: [MosaicChoice]) {
        guard let layout = MosaicGrid.layout(choices: choices, viewport: mosaicViewport) else {
            return
        }
        // Anything held down on the Mac is let go first, for the same reason changing the source
        // releases it: what is on screen is about to be a picture with no input at all, and a
        // modifier latched before that would be one nothing here can release.
        releaseLatchedModifiers()
        mosaicChoices = choices
        // Remembered as the *choices*, not as the rectangles the Mac is being sent: an
        // arrangement is a place the user returns to, and what it was for windows is what
        // survives a restart and a rotation. See ``MosaicArrangementStore``.
        if let hostID = currentHostID {
            MosaicArrangementStore.save(choices, hostID: hostID)
        }
        selectSource(.mosaic(layout))
    }

    /// The arrangement this Mac was last left in, thinned to what it still has.
    ///
    /// **Asked when the catalogue arrives**, which is the first moment anything knows which of the
    /// remembered windows still exist. A window ID outlives neither a restart nor a quit, so the
    /// list comes back as a question and the catalogue is the answer; fewer than two survivors is
    /// nothing, which is the same rule that stops a one-tile canvas being a mosaic at all.
    ///
    /// A pure lookup rather than something that sends: the caller is deciding *instead of* the
    /// default source, and a function that both answered and acted could not be used that way.
    func mosaicToRestore(hostID: String?, catalog: CaptureCatalog?) -> [MosaicChoice] {
        guard let hostID else { return [] }
        return MosaicArrangement.restored(
            MosaicArrangementStore.load(hostID: hostID),
            into: catalog
        )
    }

    /// The one source this Mac was last left on, if the Mac still has it.
    ///
    /// **Asked at the same moment as the arrangement, and answered second**: an arrangement is
    /// what the user built here, and a single source is only what they were looking at, so where
    /// both are remembered the arrangement is the one they meant. What is left when both have
    /// gone is the first display, as it always was. See ``ChosenSource``.
    ///
    /// A pure lookup rather than something that sends, exactly like
    /// ``mosaicToRestore(hostID:catalog:)`` above it: the caller is deciding *instead of* the
    /// default source, and a function that both answered and acted could not be used that way.
    func sourceToRestore(hostID: String?, catalog: CaptureCatalog?) -> CaptureSource? {
        guard let hostID else { return nil }
        return ChosenSource.restored(ChosenSourceStore.load(hostID: hostID), into: catalog)
    }

    /// Gives one tile more or less room, cycling through the sizes the control offers.
    ///
    /// **A weight rather than a size.** The user says "this one matters more" and the arithmetic
    /// decides what that means on a canvas of this shape with this many tiles beside it, which is
    /// the only version of the control that survives the user adding a seventh window afterwards.
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
    /// An ordinary source switch, deliberately: the client asks the Mac for that one source, and
    /// from that moment the session is the session it always was — full resolution, the whole
    /// input path, the adaptive quality. What is kept is the arrangement, so the tile can be
    /// given back.
    ///
    /// **A window rather than a slot, and the turn is the screen's to make.** The tap resolved an
    /// index against the arrangement *it was drawn for*, and since a reorder the Mac's answer
    /// describes the arrangement the user has just left: resolving the index here, against
    /// whatever the Mac last said, would open the window that is in that slot rather than the one
    /// under the finger. See ``RemoteScreen/shownMosaicLayout``.
    func focusMosaicTile(_ source: CaptureSource) {
        selectSource(source)
    }

    /// What the arrangement is made of, in the order it is laid out. See
    /// ``MacSession/mosaicChoices``.
    var mosaicChoicesList: [MosaicChoice] { mosaicChoices }

    /// Moves a tile within the arrangement.
    ///
    /// **The order *is* the arrangement.** The grid is filled in reading order, so moving a
    /// source up the list moves it up the picture, and there is no second thing to keep in step:
    /// no rectangle to store per tile, no drag to interpret over live video, and nothing a
    /// freeform editor would have to replace later. What a full editor would add on top of this
    /// is *sizes* rather than positions, which is why this is worth having on its own.
    func moveMosaicTile(from source: Int, to destination: Int) {
        guard mosaicChoices.indices.contains(source),
              mosaicChoices.indices.contains(destination),
              source != destination
        else { return }
        // The whole choice moves, size and all: moving a window in the picture is moving the
        // thing the user arranged, not just its place in a list of names.
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

        // **A mosaic of one is not a mosaic.** Taking the second-to-last tile away leaves one
        // window on screen, and the honest thing to show is that window on its own — an ordinary
        // source switch, with the input and the sharpness that come with it — rather than a
        // canvas holding a single tile in the corner of a grid built for two. The arrangement is
        // dropped with it, by the same rule that drops it when any other source is chosen.
        guard choices.count > 1 else {
            if let only = choices.first { selectSource(only.source) }
            return
        }
        showMosaic(choices)
    }

    /// Asks the Mac for the arrangement again, at the shape the phone is now held at.
    ///
    /// **For the rotation, which is the one thing that changes a layout's identifier without
    /// anybody choosing anything.** The canvas is built for the arrangement and the screen, so
    /// turning the phone makes the layout different — different rectangles, a different identifier
    /// — and the source the Mac is capturing keeps the old one. Left alone the app reads that as
    /// "not showing a mosaic", which is why the tile borders vanish on a turned phone while the
    /// picture goes on being an arrangement. See ``MacSession/isAskingForMosaic``.
    ///
    /// **Once the phone has stopped moving, and not while it is starting to.** The viewport changes
    /// the instant the rotation begins, so asking immediately puts the Mac's answer — a different
    /// canvas, which is a different picture, and a decoder flush before the first frame of it
    /// arrives — inside the system's own rotation animation. The result is a turn of the phone
    /// that stutters: the chrome is moving, and in the middle of it the picture goes black and
    /// comes back a different shape. Waiting a little longer than that animation costs a fifth of
    /// a second on a change that is fast now, and buys a rotation that is one movement.
    ///
    /// The wait is also a debounce, which is the second reason for it: a screen that changes size
    /// twice — a rotation reported in two steps — would otherwise be two asks, two rearrangements
    /// and two black frames.
    ///
    /// Nothing happens unless an arrangement is what the user asked for: a session on a single
    /// window with a remembered arrangement behind it must not have a mosaic put back in front of
    /// them because they turned the phone.
    func refreshMosaicForViewport() {
        mosaicViewportTask?.cancel()
        mosaicViewportTask = Task { @MainActor [weak self] in
            // Short, and it is a settle rather than a wait for a measurement. The canvas can be
            // built the moment the interface knows which way it is going, which it does at the
            // start of the movement — see ``MacSession/mosaicViewport`` — so the only question is
            // how much of the movement to overlap. A fifth of a second plus the Mac's own hundred
            // milliseconds puts the picture's own movement at the end of the screen's, which is
            // where a turn should hand over: earlier than this the two movements play at once, and
            // later is a picture that sits still while the phone finishes turning and then moves on
            // its own, which is the delay this replaced.
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

    /// Waits a moment, then closes the arrangement's gaps. See ``dropClosedMosaicTiles()``.
    ///
    /// **The grace is not politeness, it is a catalogue that is wrong more often than it looks.**
    /// One arrives for a launch, a quit, a change of Spaces and a change of screen, and it is
    /// rebuilt from a fresh enumeration each time — so a window can be missing from one and back in
    /// the next. An arrangement thinned on the first would lose the tile, re-ask the Mac for a
    /// smaller canvas, and then have to put it back: three pictures and two re-layouts for a window
    /// that never went anywhere. Two seconds is longer than any of those turns over, and short
    /// enough that a window which really has gone is gone before the user wonders about it.
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
    /// **Thinned rather than discarded: the order and the sizes survive.** A tile with a card in it
    /// is a window nobody can open and room nobody is using, and what the user arranged was "these
    /// windows, in this order, with this one bigger" — the windows that are still there keep saying
    /// that, and the grid gives their space to the ones that remain.
    ///
    /// Re-asked only when the arrangement is what is showing, because that is the only case where
    /// freeing the space is something the user can see. An arrangement thinned while one of its
    /// tiles is open is kept for the way back, which is the moment it is next drawn.
    ///
    /// Fewer than two survivors is no arrangement at all, which is the same rule a restored one is
    /// held to: a canvas with one window in it is not what a mosaic is for. See
    /// ``MacSession/mosaicToRestore(hostID:catalog:)``.
    func dropClosedMosaicTiles() {
        guard !mosaicChoices.isEmpty, let catalog = activeSession?.catalog else { return }

        let living = mosaicChoices.filter { catalog.descriptor(for: $0.source) != nil }
        // **Nothing is thrown away.** Fewer than two survivors is not an arrangement to redraw, and
        // it is not an arrangement to forget either: a catalogue can be missing a window for
        // reasons that have nothing to do with the window, and the one time this emptied the
        // arrangement the way back to it went with it, for the rest of the session. What is left
        // alone is the arrangement the user built, waiting for the windows to come back; what is
        // still an arrangement is redrawn without the gaps. See ``scheduleMosaicGapCheck()``.
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
    /// Sent as a real modifier key press rather than as flag bits on the next keystroke,
    /// because that is what the host tracks: setting `flags` describes one event and does not
    /// release the modifier, so the window server would go on believing it is held. A latched
    /// modifier is also what makes a two-finger shortcut possible from a touch screen at all —
    /// there is no way to hold ⌘ with one hand and type with the other on a phone.
    /// Latches a modifier on or off.
    ///
    /// Sent as a real modifier key press rather than as flag bits on the next keystroke,
    /// because that is what the host tracks: setting `flags` describes one event and does not
    /// release the modifier, so the window server would go on believing it is held. A latched
    /// modifier is also what makes a two-finger shortcut possible from a touch screen at all —
    /// there is no way to hold ⌘ with one hand and type with the other on a phone.
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
    /// The preview is the line the Mac has been sent since it was last emptied, and a Return is
    /// the point at which that stops describing anything: the line is committed, the field it went
    /// into has moved on, and a bar still showing the old text claims the Mac is holding something
    /// it has already taken.
    func pressReturn() {
        typedPreview = ""
        send(.keyDown(keyCode: 36, modifiers: latchedModifiers))
        send(.keyUp(keyCode: 36, modifiers: latchedModifiers))
    }

    /// Text from the software keyboard, routed by the current mode.
    /// Text from the software keyboard, routed by the current mode.
    func handleTypedText(_ text: String) {
        guard !text.isEmpty else { return }
        // A newline is a Return by another name — the software keyboard delivers it as text
        // rather than as a key — so it commits the line for the same reason ``pressReturn()``
        // does, and the preview restarts from empty.
        // Bounded, but far beyond anything the bar can draw.
        //
        // This was 40, which is *less* than a landscape bar displays. So the preview filled
        // about half the width and then stopped growing: every further character pushed the
        // text left while empty space remained to its right, because the cap was doing the
        // layout. The view already bounds what is drawn — one line, truncated at the head —
        // so this only has to stop the string growing without limit, and any number above
        // what the bar can show does that without being visible.
        typedPreview = text.contains(where: \.isNewline)
            ? ""
            : String((typedPreview + text).suffix(400))

        switch keyboardMode {
        case .unicode:
            send(.textInput(text))

        case .keycode:
            // Per character, with the latched modifiers attached, so ⌘-latched typing works.
            // A character with no Mac keycode — an emoji, a CJK glyph — falls back to a text
            // injection rather than being silently swallowed: losing it would be worse than
            // sending it by the other mode.
            for character in text {
                guard let code = KeycodeMap.macOSKeycode(forCharacter: character) else {
                    send(.textInput(String(character)))
                    continue
                }
                // Uppercase and the shifted symbols are the same key as their unshifted
                // forms, so shift has to ride along or "Hello" arrives as "hello".
                var modifiers = latchedModifiers
                if KeycodeMap.characterNeedsShift(character) { modifiers.insert(.shift) }
                send(.keyDown(keyCode: code, modifiers: modifiers))
                send(.keyUp(keyCode: code, modifiers: modifiers))
            }
        }
    }

    func handleBackspace() {
        typedPreview = String(typedPreview.dropLast())
        // 51 is Delete (backspace) on every Mac layout. Sent in both modes: in keycode mode it
        // is a real key press, and in Unicode mode there is no text to delete backwards over,
        // so a keycode is the only thing that can express it.
        send(.keyDown(keyCode: 51, modifiers: latchedModifiers))
        send(.keyUp(keyCode: 51, modifiers: latchedModifiers))
    }

    /// A key from a hardware keyboard, in keycode mode.
    /// A key from a hardware keyboard, in keycode mode.
    func handleHardwareKey(_ usage: UIKeyboardHIDUsage, down: Bool, flags: UIKeyModifierFlags) {
        guard keyboardMode == .keycode,
              let code = KeycodeMap.macOSKeycode(for: usage)
        else { return }
        let modifiers = KeycodeMap.modifiers(from: flags)
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
    /// **The one door the Settings tab uses**, and that tab is unreachable while a session is
    /// running — so the no-session branch below is not an edge case, it is the case that tab
    /// exists for. It writes the choice down and nothing more; the next session reads it back
    /// through ``storedQuality`` when it arrives.
    func setAutomaticQuality(_ automatic: Bool) {
        guard let activeSession else {
            rememberQualityChoice(automatic ? .auto : (lastManualQuality ?? streamQuality))
            return
        }
        activeSession.setAutomaticQuality(automatic)
    }

    /// Sets the preset, tells the active Mac, and remembers it.
    ///
    /// The save is what makes the Settings tab's row and this one the same setting rather than
    /// two: whichever is used, the stored token ends up saying the same thing, so the next
    /// session starts where this one was left. It is written even when there is no session to
    /// tell, which is the case the Settings tab exists for.
    func setStreamQuality(_ quality: StreamQuality) {
        guard let activeSession else {
            // No Mac to tell, and nothing to gate either: with no session there is no relay
            // carrying the bytes, which is the only thing ``MacSession/videoCeiling`` sells
            // against. The choice is simply remembered for whenever one arrives.
            rememberQualityChoice(quality)
            return
        }
        activeSession.setStreamQuality(quality)
    }

}
