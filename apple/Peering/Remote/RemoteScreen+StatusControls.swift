import PeeringKit
import RemoteCore
import SwiftUI
import UIKit

extension RemoteScreen {
    var lockDot: some View {
        Button {
            model.lockMac()
        } label: {
            Image(systemName: model.privacyModeEnabled ? "lock.shield.fill" : "lock.fill")
                .font(.system(size: 17, weight: .medium))
                .foregroundStyle(model.privacyModeEnabled ? ColorPalette.accent : ColorPalette.ink)
                .frame(width: 48, height: 48)
                .glassSurface(in: Circle())
        }
        .contentShape(Rectangle())
        .buttonStyle(RailButtonStyle(scale: 0.92))
        .contextMenu {
            // Tinted per item: SwiftUI offers no modifier on a menu's own content.
            Button { model.lockMac() } label: {
                Label("Lock screen", systemImage: "lock.fill")
            }
            .menuInk()
            Button { model.setPrivacyMode(!model.privacyModeEnabled) } label: {
                Label(
                    model.privacyModeEnabled ? "Restore display brightness" : "Dim displays",
                    systemImage: model.privacyModeEnabled ? "sun.max.fill" : "sun.min.fill"
                )
            }
            .menuInk()
        }
        .accessibilityLabel("Lock the Mac")
        .accessibilityHint("Touch and hold for Lock Screen or Dim Displays")
    }

    @ViewBuilder
    var mosaicDot: some View {
        if canReturnToMosaic {
            sessionDot(
                symbol: "rectangle.split.2x2",
                label: String(localized: "Back to the mosaic"),
                tint: ColorPalette.accent
            ) {
                // The picture is asked for at the end of the movement so the canvas arrives around a window already in place.
                animateBackToMosaic()
            }
            .transition(.scale.combined(with: .opacity))
        }
    }

    /// The way out of an arrangement in one tap: back to the Mac's first display, and the arrangement is forgotten so it does not return.
    @ViewBuilder
    var closeMosaicDot: some View {
        if model.isShowingMosaic {
            sessionDot(
                symbol: "xmark.rectangle",
                label: String(localized: "Close the mosaic", table: "Chrome")
            ) {
                guard let display = model.catalog?.displays.first ?? model.catalog?.all.first else { return }
                if let hostID = model.activeSession?.hostID { MosaicArrangementStore.save([], hostID: hostID) }
                withAnimation(Motion.settle) { model.selectSource(display) }
            }
            .transition(.scale.combined(with: .opacity))
        }
    }

    var terminalDot: some View {
        sessionDot(
            symbol: terminalRunning > 0 ? "terminal.fill" : "terminal",
            label: terminalRunning > 0
                ? model.hostPlatform.adapt(String(localized: "Mac terminals, \(terminalRunning) running"))
                : model.hostPlatform.adapt(String(localized: "Open Mac terminals")),
            tint: terminalWantsAttention ? .orange : nil,
            badge: terminalRunning > 0 ? terminalRunning : nil,
            badgeTint: terminalWantsAttention ? .orange : ColorPalette.accent
        ) {
            showsTerminals = true
        }
    }

    func sessionDot(
        symbol: String,
        label: String,
        tint: Color? = nil,
        badge: Int? = nil,
        badgeTint: Color = ColorPalette.accent,
        action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.system(size: 17, weight: .medium))
                .foregroundStyle(tint ?? ColorPalette.ink)
                .frame(width: 48, height: 48)
                // Plain glass, with the press answered by the button style so one press gets one answer.
                .glassSurface(in: Circle())
                .overlay(alignment: .topTrailing) {
                    if let badge {
                        Text("\(badge)")
                            .font(.system(size: 10, weight: .bold).monospacedDigit())
                            .foregroundStyle(ColorPalette.onInk)
                            .padding(.horizontal, 4)
                            .frame(minWidth: 15, minHeight: 15)
                            .background(badgeTint, in: Capsule())
                            // Tucked inside the circle: outside the bounds it was its own hit region and a tap on the number did nothing.
                            .offset(x: -1, y: 1)
                            .allowsHitTesting(false)
                    }
                }
        }
        // A square hit area: a circle's corners are what a thumb misses.
        .contentShape(Rectangle())
        .buttonStyle(RailButtonStyle(scale: 0.92))
        .accessibilityLabel(label)
    }

    var terminalRunning: Int { model.terminals.filter(\.isRunning).count }

    var terminalWantsAttention: Bool { model.terminals.contains { $0.attention != nil } }

    /// Settings cannot be opened while a session runs, which is the only time anybody wants to silence a Mac, so the switch has to live here.
    var soundButton: some View {
        Button {
            withAnimation(Motion.settle) { model.hostAudioMuted.toggle() }
        } label: {
            HStack(spacing: 5) {
                Image(systemName: model.hostAudioMuted ? "speaker.slash" : "speaker.wave.2")
                Text(model.hostAudioMuted ? "Unmute" : "Mute")
            }
            .foregroundStyle(ColorPalette.ink)
            .pillChip(filling: true)
        }
        .buttonStyle(RailButtonStyle(scale: 0.9))
        .menuInk()
        .accessibilityLabel(model.hostAudioMuted ? "Unmute the Mac" : "Mute the Mac")
    }

    /// A `Button` rather than a `Menu`: as a menu label it drew a visibly different shade from its neighbours, something the menu drew rather than anything set here.
    /// The two words are one letter apart and mean opposite things, so the arrow carries as much as the word.
    var fillChip: some View {
        Button {
            setFill(!scalesToFill)
        } label: {
            HStack(spacing: 5) {
                Image(systemName: scalesToFill
                      ? "arrow.up.left.and.arrow.down.right"
                      : "arrow.down.right.and.arrow.up.left")
                Text(scalesToFill ? "Fill" : "Fit")
            }
            .foregroundStyle(ColorPalette.ink)
            .pillChip(filling: true)
        }
        .buttonStyle(RailButtonStyle(scale: 0.94))
        .accessibilityLabel("How the picture fits the screen")
        .accessibilityValue(scalesToFill ? "Filling this screen" : "Fitting the whole screen")
    }

    func setFill(_ filled: Bool) {
        withAnimation(Motion.settle) {
            scalesToFill = filled
            // The pan belongs to the old scale: a picture panned to the edge of a fitted frame is off-screen once it grows to fill.
            pan = .zero
        }
    }

    func expandStatusBar() {
        withAnimation(Motion.morph) {
            statusBarExpanded = true
        }
        // Held so a manual collapse cancels the timer: otherwise the pending collapse fires anyway and springs a hand-closed panel shut again.
        statusBarCollapseTask?.cancel()
        statusBarCollapseTask = Task {
            try? await Task.sleep(for: .seconds(2.5))
            guard !Task.isCancelled else { return }
            collapseStatusBar()
        }
    }

    func collapseStatusBar() {
        statusBarCollapseTask?.cancel()
        statusBarCollapseTask = nil
        withAnimation(Motion.morph) {
            statusBarExpanded = false
        }
    }
}
