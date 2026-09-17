import RemoteCore
import SwiftUI

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
        UserDefaults.standard.set(pointerSpeed, forKey: "Peering.pointerSpeed")
    }

    /// How the speed is written: "1×", "1.5×", "2×".
    var pointerSpeedLabel: String {
        pointerSpeed == pointerSpeed.rounded()
            ? "\(Int(pointerSpeed))"
            : String(format: "%.1f", pointerSpeed)
    }

    func send(_ command: RemoteCommand) {
        guard !isObserving || !command.isUserInput else { return }
        session?.send(command)
    }

    func setObserveOnly(_ enabled: Bool) {
        guard enabled != isObserving else { return }

        // A modifier that was latched before Observe was selected must be released on the Mac.
        // Clearing only the phone's visual state would leave Command/Shift held remotely with
        // Observe mode deliberately blocking the button that could release it.
        if enabled {
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
        isObserving = enabled
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
        activeSourceID = descriptor.id
        session?.selectCaptureSource(descriptor.source)
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
        session?.selectCaptureSource(source)
    }

    func launchApplication(_ descriptor: InstalledApplicationDescriptor) {
        send(.launchApplication(bundleIdentifier: descriptor.bundleIdentifier))
    }

    func setKeyboardMode(_ mode: KeyboardMode) {
        keyboardMode = mode
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

    /// The title of the currently active capture source (display name or app name).
    func setStreamQuality(_ quality: StreamQuality) {
        streamQuality = quality
        if let bitrateKbps = quality.bitrateKbps {
            send(.setStreamQuality(fps: 0, bitrateKbps: bitrateKbps))
        } else {
            autoQualityPolicy = AutoQualityPolicy(path: autoQualityPath)
            lastAutoDroppedFrames = renderer.currentSnapshot.framesDropped
            send(.setStreamQuality(fps: 0, bitrateKbps: autoQualityPolicy.tier.bitrateKbps))
        }
    }

    func applyInitialAutoQualityIfNeeded() {
        guard streamQuality == .auto else { return }
        autoQualityPolicy = AutoQualityPolicy(path: autoQualityPath)
        lastAutoDroppedFrames = 0
        send(.setStreamQuality(fps: 0, bitrateKbps: autoQualityPolicy.tier.bitrateKbps))
    }

    func updateAutoQuality(from snapshot: VideoRenderer.Snapshot) {
        guard streamQuality == .auto, let latencyMilliseconds else {
            lastAutoDroppedFrames = snapshot.framesDropped
            return
        }

        let newDrops = snapshot.framesDropped >= lastAutoDroppedFrames
            ? snapshot.framesDropped - lastAutoDroppedFrames
            : 0
        lastAutoDroppedFrames = snapshot.framesDropped

        guard let tier = autoQualityPolicy.observe(
            latencyMilliseconds: latencyMilliseconds,
            newDroppedFrames: newDrops
        ) else { return }
        send(.setStreamQuality(fps: 0, bitrateKbps: tier.bitrateKbps))
        append(note: "Auto quality changed to \(tier.bitrateKbps / 1_000) Mbps")
    }

}
