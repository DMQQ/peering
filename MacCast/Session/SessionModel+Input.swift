import CoreMedia
import MacCastKit
import RemoteCore
import SwiftUI
import UIKit

extension SessionModel {
    /// The only path input takes: everything goes through the session's coalescer, so the merge and never-drop rules live in one place.
    /// The speeds the joystick's double tap steps through, and back to the start.
    /// Halves for the first step: 1× is too slow for crossing a 5K display and the first thing anyone wants is a little more.
    static let pointerSpeeds: [Double] = [1, 1.5, 2, 2.5, 3]

    func cyclePointerSpeed() {
        Analytics.featureUsed(.pointerSpeedChanged)
        let speeds = Self.pointerSpeeds
        // `firstIndex` on the value, not a stored index: a speed not in the list (an older build's or hand-edited default) restarts the cycle instead of trapping.
        let index = speeds.firstIndex(of: pointerSpeed) ?? 0
        pointerSpeed = speeds[(index + 1) % speeds.count]
        UserDefaults.standard.set(pointerSpeed, forKey: PreferenceKeys.pointerSpeed)
    }

    var pointerSpeedLabel: String {
        pointerSpeed == pointerSpeed.rounded()
            ? "\(Int(pointerSpeed))"
            : String(format: "%.1f", pointerSpeed)
    }

    func send(_ command: RemoteCommand) {
        // Two rules: observe mode blocks all of `isUserInput`, while a mosaic only lacks a window for a point, so it blocks points and keystrokes but not Space switching. See `isBlockedByMosaic`.
        guard !isObserving || !command.isUserInput else { return }
        guard !isShowingMosaic || !command.isBlockedByMosaic else { return }
        session?.send(command)
    }

    func setObserveOnly(_ enabled: Bool) {
        Analytics.featureUsed(.observeOnlyChanged)
        guard enabled != isObserving else { return }
        if enabled { releaseLatchedModifiers() }
        isObserving = enabled
    }

    /// Every mode that stops the user's keys reaching the Mac must call this: a modifier latched before cannot be released by its own key-up, which the mode refuses to send, and the next session's typing would inherit Command or Shift.
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
        Analytics.featureUsed(.privacyModeChanged)
        guard phase == .ready else { return }
        privacyModeEnabled = enabled
        send(.setPrivacyMode(enabled: enabled))
    }

    func lockMac() {
        Analytics.featureUsed(.macLocked)
        guard phase == .ready else { return }
        send(.lockScreen)
    }

    func selectSource(_ descriptor: CaptureSourceDescriptor) {
        // Through the source: a descriptor's id is its source's stable id, and the command must not be sent without recording the choice.
        selectSource(descriptor.source)
    }

    /// Recording the choice is the point: `activeSourceID` is what callers compare before switching, so a caller that sends `setCaptureSource` itself leaves a stale record and the next switch back reads as "already there".
    /// Shows the display with the Mac's lock screen and opens the keyboard for the password.
    /// The source it leaves is restored when the Mac reports the lock is gone.
    func showLockScreen(on displayID: UInt32) {
        Analytics.featureUsed(.lockScreenShown)
        guard let session = activeSession else { return }
        let current: CaptureSource? = activeSourceID?.hasPrefix("mosaic:") == true
            ? session.askedMosaicLayout.map { .mosaic($0) }
            : catalog?.all.first { $0.id == activeSourceID }?.source
        let lockScreen = CaptureSource.display(displayID)
        if let current, current.stableID != lockScreen.stableID {
            session.unlockDetour = (lockScreen, current)
        }
        selectSource(lockScreen)
        showKeyboard = true
    }

    func selectSource(_ source: CaptureSource) {
        Analytics.featureUsed(.sourceSelected)
        // Read before the write below: it answers "was this end showing an arrangement a moment ago".
        let wasArrangement = activeSourceID?.hasPrefix("mosaic:") == true
        activeSourceID = source.stableID
        activeSession?.isAskingForMosaic = source.isMosaic
        // The ask as made is what the Mac builds; the arrangement computed later is not.
        if case .mosaic(let layout) = source {
            activeSession?.askedMosaicLayout = layout
            // The arrangement asked for is the one on screen if a config naming this exact mosaic arrived first (a reconnect where the Mac's cached description beat the catalogue), or this end was already showing one and asks for the same again: the Mac answers an ask it is already capturing with no config. The canvas settles the second case. See `CGSize/matches(_:)`.
            if activeSession?.picture?.sourceID == source.stableID
                || (wasArrangement && activeSession?.picture?.pixelSize.matchesCanvas(layout.canvas) == true) {
                activeSession?.pictureMosaicLayout = layout
            }
        } else {
            activeSession?.askedMosaicLayout = nil
        }

        // The only place the user's choice can be saved: every source asked for arrives here, and a save at each door is one a door can miss.
        // The default a session picks for itself never comes through here: the app choosing the first display is not the user choosing.
        // A mosaic is passed over: it has its own store, and leaving the single source untouched lets a Mac whose arrangement lost a window fall back to it.
        if !source.isMosaic, let hostID = currentHostID {
            ChosenSourceStore.save(source, hostID: hostID)
        }

        // A remembered arrangement lasts as long as the user is inside it: selecting one of its tiles keeps it, selecting anything else leaves it behind.
        if !source.isMosaic,
           !mosaicChoices.contains(where: { $0.source == source }) {
            mosaicChoices = []
        }

        session?.selectCaptureSource(source)
    }

    // MARK: - The mosaic

    /// The canvas is the phone's screen in pixels: a smaller one makes every tile soft before the encoder sees it, and the Mac trims a larger one.
    func showMosaic(_ sources: [CaptureSource]) {
        Analytics.featureUsed(.mosaicShown)
        showMosaic(sources.map { MosaicChoice(source: $0) })
    }

    /// - Parameter remembering: false when restoring, which must not write what it thinned: a window the catalogue merely failed to list would be lost from the store.
    func showMosaic(_ choices: [MosaicChoice], remembering: Bool = true) {
        Analytics.featureUsed(.mosaicShown)
        // Shaped by the choices being asked for, not those on screen: a restore runs before the new choices are stored and would shape its canvas from the fallback aspect.
        guard let layout = MosaicGrid.layout(
            choices: choices,
            viewport: mosaicViewport,
            tileAspect: activeSession?.tileAspect(for: choices) ?? MosaicGrid.windowAspect
        ) else {
            return
        }
        // Anything held down is let go first: the picture is about to take no input, and nothing could release a modifier latched before.
        releaseLatchedModifiers()
        // A tile that opened nothing last time gets another try: this is the user asking, not the app re-using the arrangement.
        sourcesThatOpenedNothing = []
        mosaicChoices = choices
        // Remembered as the choices, not the rectangles sent: the windows survive a restart and a rotation.
        if remembering, let hostID = currentHostID {
            MosaicArrangementStore.save(choices, hostID: hostID)
        }
        selectSource(.mosaic(layout))
    }

    /// Asked when the catalogue arrives, the first moment anything knows which windows still exist (a window ID outlives neither a restart nor a quit). Fewer than two survivors is nothing.
    /// A pure lookup: the caller decides instead of the default source.
    /// An arrangement the plan no longer includes is not restored: a reconnection is not a way round the gate.
    func mosaicToRestore(hostID: String?, catalog: CaptureCatalog?) -> [MosaicChoice] {
        guard let hostID, storeManager.access.includes(.mosaic) else { return [] }
        return MosaicArrangement.restored(
            MosaicArrangementStore.load(hostID: hostID),
            into: catalog
        )
    }

    /// The arrangement wins where both are remembered; with neither, the first display.
    /// A virtual display is not restored on a plan without one: that would be a padlock a reconnection walks around.
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

    /// A weight, not a size: it survives a seventh window being added.
    func stepMosaicTileSize(at index: Int, by step: Int) {
        Analytics.featureUsed(.mosaicTileResized)
        guard mosaicChoices.indices.contains(index) else { return }
        let current = mosaicChoices[index].weight
        let next = min(max(current + step, MosaicChoice.minimumWeight), MosaicChoice.maximumWeight)
        guard next != current else { return }

        var choices = mosaicChoices
        choices[index].weight = next
        showMosaic(choices)
    }

    /// A window rather than a slot: a reorder makes the Mac's answer describe the arrangement just left, so resolving an index here would open the wrong window.
    func focusMosaicTile(_ source: CaptureSource) {
        selectSource(source)
    }

    var mosaicChoicesList: [MosaicChoice] { mosaicChoices }

    func moveMosaicTile(from source: Int, to destination: Int) {
        guard mosaicChoices.indices.contains(source),
              mosaicChoices.indices.contains(destination),
              source != destination
        else { return }
        var choices = mosaicChoices
        let moved = choices.remove(at: source)
        choices.insert(moved, at: destination)
        showMosaic(choices)
    }

    func removeMosaicTile(at index: Int) {
        Analytics.featureUsed(.mosaicTileRemoved)
        guard mosaicChoices.indices.contains(index) else { return }
        var choices = mosaicChoices
        choices.remove(at: index)

        // A mosaic of one is not a mosaic: show that window on its own as an ordinary source switch.
        guard choices.count > 1 else {
            // The arrangement goes too: `selectSource(_:)` drops one only for a source that is not a tile, and this is one, so without it the Mac shows the window while this end still describes a mosaic.
            if let hostID = currentHostID {
                MosaicArrangementStore.save([], hostID: hostID)
            }
            mosaicChoices = []
            if let only = choices.first { selectSource(only.source) }
            return
        }
        showMosaic(choices)
    }

    /// The rotation changes a layout's identifier while the Mac's capture keeps the old one, which this end reads as "not showing a mosaic" and the borders vanish.
    /// Asked once the phone has stopped moving: asking at the start puts a different canvas and a decoder flush before the first frame, inside the system's rotation animation. Also a debounce.
    /// Nothing happens unless an arrangement is what the user asked for.
    func refreshMosaicForViewport() {
        mosaicViewportTask?.cancel()
        mosaicViewportTask = Task { @MainActor [weak self] in
            // A settle, not a wait for a measurement: a fifth of a second plus the Mac's hundred milliseconds ends the picture's movement with the screen's.
            try? await Task.sleep(for: .milliseconds(200))
            guard !Task.isCancelled, let self else { return }
            guard activeSession?.isAskingForMosaic == true, !mosaicChoicesList.isEmpty else { return }
            showMosaic(mosaicChoicesList)
        }
    }

    private var mosaicViewportTask: Task<Void, Never>? {
        get { activeSession?.mosaicViewportTask }
        set { activeSession?.mosaicViewportTask = newValue }
    }

    private var mosaicGapTask: Task<Void, Never>? {
        get { activeSession?.mosaicGapTask }
        set { activeSession?.mosaicGapTask = newValue }
    }

    var sourcesThatOpenedNothing: Set<String> {
        get { activeSession?.sourcesThatOpenedNothing ?? [] }
        set { activeSession?.sourcesThatOpenedNothing = newValue }
    }

    var tileOpeningWatch: Task<Void, Never>? {
        get { activeSession?.tileOpeningWatch }
        set { activeSession?.tileOpeningWatch = newValue }
    }

    /// A catalogue is rebuilt from a fresh enumeration each time, so a window can be missing from one and back in the next; thinning on the first would lose the tile and re-ask for a smaller canvas.
    func scheduleMosaicGapCheck() {
        mosaicGapTask?.cancel()
        mosaicGapTask = Task { @MainActor [weak self] in
            try? await Task.sleep(for: .seconds(2))
            guard !Task.isCancelled, let self else { return }
            self.dropClosedMosaicTiles()
        }
    }

    /// Thinned rather than discarded, so order and sizes survive.
    /// Re-asked only when the arrangement is showing; one thinned while a tile is open is kept for the way back. Fewer than two survivors is no arrangement.
    func dropClosedMosaicTiles() {
        guard !mosaicChoices.isEmpty, let catalog = activeSession?.catalog else { return }

        let living = mosaicChoices.filter { catalog.descriptor(for: $0.source) != nil }
        // Nothing is thrown away: a catalogue can miss a window for reasons unrelated to the window, so the arrangement waits for it to come back.
        guard living.count > 1, living.count != mosaicChoices.count else { return }

        if isShowingMosaic || isAskingForMosaic {
            showMosaic(living)
        } else {
            mosaicChoices = living
        }
    }

    func returnToMosaic() {
        guard let layout = mosaicLayout else { return }
        // Nothing in an arrangement takes typing: the host refuses input while a mosaic is up.
        showKeyboard = false
        selectSource(.mosaic(layout))
    }

    func launchApplication(_ descriptor: InstalledApplicationDescriptor) {
        Analytics.featureUsed(.applicationLaunched)
        send(.launchApplication(bundleIdentifier: descriptor.bundleIdentifier))
    }

    func setKeyboardMode(_ mode: KeyboardMode) {
        Analytics.featureUsed(.keyboardModeChanged)
        keyboardMode = mode
        UserDefaults.standard.set(mode.rawValue, forKey: PreferenceKeys.keyboardMode)
    }

    /// Sent as a real modifier key press, not flag bits: `flags` describes one event and does not release the modifier, so the window server would think it held.
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

    func pressReturn() {
        typedPreview = ""
        send(.keyDown(keyCode: 36, modifiers: latchedModifiers))
        send(.keyUp(keyCode: 36, modifiers: latchedModifiers))
        // The keyboard goes with the line: the bar and its field exist only while it is up, so this empties the field from every door into a commit.
        showKeyboard = false
    }

    func handleTypedText(_ text: String) {
        guard !text.isEmpty else { return }
        // A newline is a Return delivered as text, so it commits the line.
        // Bounded far beyond anything the bar draws; it only stops unbounded growth.
        typedPreview = text.contains(where: \.isNewline)
            ? ""
            : String((typedPreview + text).suffix(400))

        switch keyboardMode {
        case .unicode:
            send(.textInput(text))

        case .keycode:
            // Per character with latched modifiers attached; a character with no Mac keycode (emoji, CJK) falls back to text injection.
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

    func handleHardwareKey(_ usage: UIKeyboardHIDUsage, down: Bool, flags: UIKeyModifierFlags) {
        guard keyboardMode == .keycode,
              let code = KeycodeMap.macOSKeycode(for: usage)
        else { return }
        // The latch rides along: a modifier held on the Mac must be in the flags of every event sent meanwhile.
        let modifiers = KeycodeMap.modifiers(from: flags).union(latchedModifiers)
        send(down ? .keyDown(keyCode: code, modifiers: modifiers)
                  : .keyUp(keyCode: code, modifiers: modifiers))
    }

    // MARK: - Geometry

    var isAutomaticQuality: Bool {
        activeSession?.isAutomaticQuality ?? (streamQuality == .auto)
    }

    var videoCeiling: AutoQualityPolicy.Tier {
        activeSession?.videoCeiling ?? .high
    }

    /// The Settings tab is unreachable mid-session, so the no-session branch is the case it exists for: it writes the choice down and the next session reads it back.
    func setAutomaticQuality(_ automatic: Bool) {
        Analytics.featureUsed(.autoQualityChanged)
        guard let activeSession else {
            rememberQualityChoice(automatic ? .auto : (lastManualQuality ?? streamQuality))
            return
        }
        activeSession.setAutomaticQuality(automatic)
    }

    /// Saving makes the Settings row and this one the same setting. Written even with no session.
    func setStreamQuality(_ quality: StreamQuality) {
        Analytics.featureUsed(.qualityChanged)
        guard let activeSession else {
            // No Mac to tell and nothing to gate: with no session no relay carries the bytes.
            rememberQualityChoice(quality)
            return
        }
        activeSession.setStreamQuality(quality)
    }

}
