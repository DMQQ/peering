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
        // **Two reasons a command is not sent, and they are different reasons.** Observe mode is
        // the user saying they do not want to touch the Mac; a mosaic is the app saying it does
        // not yet know *which* Mac window a point means, because that is decided by which tile
        // it landed in and the tile is chosen here rather than posted over there. Both resolve to
        // the same rule, which is why they share the one guard rather than sitting in two places
        // that could drift.
        guard (!isObserving && !isShowingMosaic) || !command.isUserInput else { return }
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
        selectSource(.mosaic(layout))
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
    func focusMosaicTile(_ index: Int) {
        guard let layout = mosaicLayout, layout.tiles.indices.contains(index) else { return }
        selectSource(layout.tiles[index].source)
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

    /// Goes back to the whole arrangement.
    func returnToMosaic() {
        guard let layout = mosaicLayout else { return }
        selectSource(.mosaic(layout))
    }

    /// The phone's screen in pixels, which is the canvas a mosaic is asked for.
    ///
    /// Read from the window scene rather than from `UIScreen.main`, which is deprecated and,
    /// on a device with more than one scene, is not necessarily the one being looked at.
    private var mosaicCanvasPixels: CGSize {
        let scenes = UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }
        guard let scene = scenes.first(where: { $0.activationState == .foregroundActive }) ?? scenes.first
        else {
            // No scene at all, which is a state the app cannot act in rather than a case to
            // handle: a canvas that a Mac will accept, so nothing downstream has to.
            return CGSize(width: 1280, height: 720)
        }
        let bounds = scene.screen.bounds
        let scale = scene.screen.scale
        return MosaicGrid.canvas(
            for: CGSize(width: bounds.width * scale, height: bounds.height * scale)
        )
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
