import MacCastKit
import RemoteCore
import SwiftUI
import UIKit

extension RemoteScreen {
    // MARK: - Status

    /// A `RoundedRectangle` not a `Capsule`: the corner radius carries the animation, and shape and clip read one property so glass and content agree about the edge.
    var pillShape: RoundedRectangle {
        RoundedRectangle(
            cornerRadius: statusBarExpanded
                ? ChromeMetrics.pillExpandedRadius
                : ChromeMetrics.pillCollapsedRadius,
            style: .continuous
        )
    }

    /// Delayed on the way in, so the contents land into a shape that has already started to open.
    /// Leaving is not animated: a view being removed stays in its parent's layout for its removal transition, so the pill would sit at its open size through the fade. The clip closes over the content instead.
    static let pillContents = AnyTransition.asymmetric(
        insertion: .opacity.animation(.easeOut(duration: 0.22).delay(0.06)),
        removal: .identity
    )

    /// Portrait opens nearly to the glass: tied to the closed bar's measured width it came out short whenever the names were short.
    /// Not edge to edge: the display's round corners would cut a flush panel.
    /// Landscape keeps the closed bar's width: the panel shares the screen with the rails.
    /// Nil until the closed bar has been measured once.
    func expandedPanelWidth(availableWidth: CGFloat) -> CGFloat? {
        guard collapsedBarWidth > 0, availableWidth > 0 else { return nil }
        guard !deviceIsLandscape else { return collapsedBarWidth }
        return availableWidth - ChromeMetrics.edgeInset * 2
    }

    func statusBar(availableWidth: CGFloat) -> some View {
        HStack(alignment: .center, spacing: 5) {
            if !statusBarExpanded {
                lockDot.layoutPriority(1)
            }
            statusPill(availableWidth: availableWidth)
            if !statusBarExpanded {
                mosaicDot.layoutPriority(1)
                terminalDot.layoutPriority(1)
            }
        }
        // The closed bar's width, taken while closed: the panel opens into this much so the pill swallows the circles' space instead of the bar shrinking.
        .onGeometryChange(for: CGFloat.self) { $0.size.width } action: { width in
            guard !statusBarExpanded else { return }
            collapsedBarWidth = width
        }
        // The one animation on this bar, for what the pill holds: without it the rows would jump in the frame the picture changes. Keyed on one condition so it does not fight the pill's own spring.
        .animation(Motion.settle, value: canReturnToMosaic)
        // Narrower than the rails' inset on purpose: the pill's rows need the width.
        .padding(.horizontal, 6)
        .padding(.top, ChromeMetrics.edgeInset)
        .reportChromeFrame(.statusBar, into: $chromeFrames)
    }

    func statusPill(availableWidth: CGFloat) -> some View {
        // A `ZStack`, not a `Group`: a `Group` is transparent, so glass, clip and corner were a shape per state and flipping the branch cross-faded two shapes instead of growing one. Top-aligned because both states are briefly present and the pill should only grow downwards.
        ZStack(alignment: .top) {
            if statusBarExpanded {
                VStack(alignment: .leading, spacing: 10) {
                    HStack(spacing: 8) {
                        // Green once the session is up, not merely connected; the same dot as the closed pill's.
                        Circle()
                            .fill(isReconnectingToMac ? ColorPalette.caution : (model.phase == .ready ? Color.green : ColorPalette.ink))
                            .frame(width: 7, height: 7)
                        Text(model.shownHostName ?? "Mac")
                            .font(.subheadline.weight(.semibold))
                            .lineLimit(1)
                            .truncationMode(.tail)
                        // The name yields to the path, which is fixed width. No latency figure here: the Sessions tab holds it.
                        Spacer(minLength: 8)
                        connectionPathChip
                    }

                    // A row's chips go through `AnyView` as a crash fix: the row's mangled type grew too deep, and demangling it overflowed the main thread's stack (SIGSEGV in `decodeMangledType` under `soundButton`).
                    actionRow(String(localized: "Stream"), systemImage: "play.rectangle") {
                        AnyView(Group {
                        soundButton
                        Button { ScreenshotShare.present(hostName: model.hostName) } label: {
                            HStack(spacing: 5) {
                                Image(systemName: "camera")
                                Text("Screenshot")
                            }
                            .foregroundStyle(ColorPalette.ink)
                            .pillChip(filling: true)
                        }
                        .buttonStyle(.plain)
                        .accessibilityLabel("Take screenshot")
                        })
                    }

                    // Every chip is an equal slot, so "Immersive" did not fit on the four-chip row above; erased like that one for the same reason.
                    actionRow(String(localized: "View"), systemImage: "eye") {
                        AnyView(Group {
                        fillChip
                        if zoom > 1.01 {
                            Button {
                                resetPicture()
                            } label: {
                                Text("\(Int((zoom * 100).rounded()))%")
                                    .monospacedDigit()
                                    .pillChip(filling: true)
                            }
                            .buttonStyle(RailButtonStyle(scale: 0.9))
                        }
                        actionChip(
                            String(localized: "Immersive"),
                            systemImage: "arrow.up.left.and.arrow.down.right"
                        ) {
                            enterImmersive()
                        }
                        })
                    }

                    actionRow(String(localized: "Mac"), systemImage: "macbook") {
                        actionChip(String(localized: "Lock"), systemImage: "lock.fill") { model.lockMac() }
                        actionChip(
                            model.privacyModeEnabled ? String(localized: "Restore") : String(localized: "Darken"),
                            systemImage: model.privacyModeEnabled ? "sun.max" : "sun.min"
                        ) {
                            model.setPrivacyMode(!model.privacyModeEnabled)
                        }
                    }

                    actionRow(String(localized: "Session"), systemImage: "antenna.radiowaves.left.and.right") {
                        actionChip(String(localized: "Connect"), systemImage: "macbook.and.iphone") {
                            model.stepAwayFromSession()
                        }
                        actionChip(
                            String(localized: "Terminal"),
                            systemImage: terminalRunning > 0 ? "terminal.fill" : "terminal",
                            tint: terminalWantsAttention ? .orange : nil
                        ) {
                            showsTerminals = true
                        }
                        if canReturnToMosaic {
                            actionChip(
                                String(localized: "Mosaic"),
                                systemImage: "rectangle.split.2x2",
                                tint: ColorPalette.accent
                            ) {
                                animateBackToMosaic()
                            }
                        }
                    }

                    // Filled red: this control cannot be taken back by pressing it again.
                    actionRow(String(localized: "End"), systemImage: "power") {
                        actionChip(String(localized: "Quit"), isDestructive: true) { model.disconnect() }
                    }
                }
                // Wider on the right: a control flush against the glass reads as clipped, a label is fine at the edge.
                .padding(.leading, 16)
                .padding(.trailing, 20)
                .padding(.vertical, 10)
                // Fixed rather than a floor: a panel that could grow would leave narrower rows ending short of the glass.
                .frame(width: expandedPanelWidth(availableWidth: availableWidth), alignment: .leading)
                .contentShape(Rectangle())
                .onTapGesture { collapseStatusBar() }
                // Opacity only, on its own clock: a scale made the two states cross-fade as if unrelated, and the pill shape carries the movement.
                .transition(Self.pillContents)
            } else {
                HStack(spacing: 8) {
                    VStack(alignment: .leading, spacing: 2) {
                        HStack(spacing: 7) {
                            // The pill's whole report on whether the session is working.
                            // Green when connected and sending, red when connected and stopped.
                            // Green because the host picker already spends green on "this Mac is reachable".
                            // No latency figure: a number here reads as a warning even at 90 ms and frightens people into closing a session.
                            Circle()
                                .fill(connectionDotTint)
                                .frame(width: 6, height: 6)
                                .accessibilityLabel(connectionDotLabel)
                            Text(model.shownHostName ?? "Mac")
                                .font(.caption.weight(.semibold))
                                .lineLimit(1)
                        }

                        HStack(spacing: 6) {
                            // A Mac being put back has no source to name; leaving the last window's title up described a session no longer there.
                            if isReconnectingToMac {
                                Text("Reconnecting…")
                                    .font(.caption2)
                                    .foregroundStyle(ColorPalette.caution)
                                    .lineLimit(1)
                            } else if let sourceTitle = model.activeSourceTitle {
                                Text(sourceTitle)
                                    .font(.caption2)
                                    .foregroundStyle(.secondary)
                                    .lineLimit(1)
                                    // The name yields and the control does not: a window's title is unbounded, and laid out as equals it squeezed the way back out of the mosaic to nothing.
                                    .layoutPriority(0)
                            }
                            connectionPathChip
                        }
                        .padding(.leading, 13)
                    }

                    Image(systemName: "chevron.down")
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundStyle(.tertiary)
                }
                .padding(.leading, 16)
                .padding(.trailing, 20)
                .padding(.vertical, 8)
                // A fixed height: a pill that resized itself as the source changed would move the picture under a finger aiming at it.
                .frame(height: 56)
                .onTapGesture { expandStatusBar() }
                .contentShape(pillShape)
                .transition(Self.pillContents)
            }
        }
        // Clipped to the shape, not the bounds: `.clipped()` left contents showing outside the rounded edge. It also covers mid-flight, since content is laid out at final size from the first frame of the spring.
        .clipShape(pillShape)
        .glassSurface(in: pillShape)
    }




    /// A Mac being put back is neither green nor red: the frames stopping is why the retry exists.
    /// Read from the session, not `isResuming`: that flag clears on the first phase holding a session, which a dial is.
    var isReconnectingToMac: Bool { model.isBeingPutBack }

    /// Amber is the palette's caution: a reconnection is not a failure.
    var connectionDotTint: Color {
        if isReconnectingToMac { return ColorPalette.caution }
        return model.isVideoStreaming ? .green : .red
    }

    var connectionDotLabel: String {
        if isReconnectingToMac { return String(localized: "Reconnecting to the Mac") }
        return model.isVideoStreaming ? String(localized: "Connected") : String(localized: "Not streaming")
    }

    var connectionPathChip: some View {
        Text(connectionPathTitle)
            .font(.caption2.weight(.bold))
            .tracking(0.5)
            .foregroundStyle(.secondary)
            .pillChip()
            .accessibilityLabel("Connection path, \(connectionPathTitle)")
    }

    /// The second fact appears only when different: on a LAN the picture already goes direct.
    /// Read from `usedDirectPath`, not the path above: a punched session still has its control connection relayed (and metered), only the picture went around.
    private var connectionPathTitle: String {
        let connection = model.connectionPath?.rawValue ?? "None"
        guard model.usedDirectPath, model.connectionPath == .relay else { return connection }
        return "\(connection)·P2P"
    }

    /// Short words on purpose: a long label takes width from its neighbours in the equal-slot row.
    func actionChip(
        _ label: String,
        systemImage: String? = nil,
        isDestructive: Bool = false,
        tint: Color? = nil,
        action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            HStack(spacing: 5) {
                if let systemImage {
                    Image(systemName: systemImage)
                }
                Text(LocalizedStringKey(label))
                    .lineLimit(1)
            }
            .foregroundStyle(tint ?? (isDestructive ? ColorPalette.onInk : ColorPalette.ink))
            .pillChip(filling: true, destructive: isDestructive)
        }
        .buttonStyle(RailButtonStyle(scale: 0.94))
    }

    /// Wide enough for "Session" with its glyph, so that both groups' chips start on one line.
    static let actionLabelWidth: CGFloat = 74

    func actionRow<Content: View>(
        _ title: String,
        systemImage: String,
        @ViewBuilder content: () -> Content
    ) -> some View {
        HStack(alignment: .top, spacing: 8) {
            Controls.sectionLabel(title, systemImage: systemImage)
                .frame(width: Self.actionLabelWidth, alignment: .leading)
                // Against the first row of chips: a 28pt chip centres its 12pt line seven points down.
                .padding(.top, 7)
            ChipSlots { content() }
        }
    }

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

    var terminalDot: some View {
        sessionDot(
            symbol: terminalRunning > 0 ? "terminal.fill" : "terminal",
            label: terminalRunning > 0
                ? String(localized: "Mac terminals, \(terminalRunning) running")
                : String(localized: "Open Mac terminals"),
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

    private var terminalRunning: Int { model.terminals.filter(\.isRunning).count }
    private var terminalWantsAttention: Bool { model.terminals.contains { $0.attention != nil } }

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

/// A flat fill rather than a material: the chips sit inside the pill's own glass.
/// No selected state: the accent means "this one is on" elsewhere, and a blue chip read as another kind of control.
extension View {
    @ViewBuilder
    func pillChip(
        filling: Bool = false,
        destructive: Bool = false
    ) -> some View {
        let chip = self
            .font(.system(size: 12, weight: .medium))
            .padding(.horizontal, 7)
            .frame(height: 28)
            .frame(maxWidth: filling ? .infinity : nil)

        // The plain chip's colour is the caller's: the secondary grey made a row of controls read as switched off.
        if destructive {
            chip
                // A filled chip carries the palette's `onInk`: white on the red is unreadable.
                .foregroundStyle(ColorPalette.onInk)
                .background(ColorPalette.danger, in: Capsule())
        } else {
            chip.background(.primary.opacity(0.08), in: Capsule())
        }
    }
}

/// Equal slots, not a flow: a flow gave every chip its own width and rows ended ragged. Words are chosen to fit the slot.
private struct ChipSlots: Layout {
    var spacing: CGFloat = 6

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let count = subviews.count
        guard count > 0 else { return .zero }
        let height = subviews.map { $0.sizeThatFits(.unspecified).height }.max() ?? 0
        guard let width = proposal.width else {
            let natural = subviews.reduce(CGFloat.zero) { $0 + $1.sizeThatFits(.unspecified).width }
            return CGSize(width: natural + spacing * CGFloat(count - 1), height: height)
        }
        return CGSize(width: width, height: height)
    }

    func placeSubviews(
        in bounds: CGRect,
        proposal: ProposedViewSize,
        subviews: Subviews,
        cache: inout ()
    ) {
        let count = CGFloat(subviews.count)
        guard count > 0 else { return }
        let slot = (bounds.width - spacing * (count - 1)) / count
        for (index, subview) in subviews.enumerated() {
            subview.place(
                at: CGPoint(x: bounds.minX + (slot + spacing) * CGFloat(index), y: bounds.minY),
                anchor: .topLeading,
                proposal: ProposedViewSize(width: slot, height: bounds.height)
            )
        }
    }
}
