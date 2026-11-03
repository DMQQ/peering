import PeeringKit
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

    /// Erased: with the pill's rows inside, the chrome's generic type grew deep enough that resolving its metadata overflowed the main thread's stack on the first draw of a session.
    func statusBar(availableWidth: CGFloat) -> AnyView {
        AnyView(HStack(alignment: .center, spacing: 5) {
            if !statusBarExpanded {
                lockDot.layoutPriority(1)
            }
            statusPill(availableWidth: availableWidth)
            if !statusBarExpanded {
                mosaicDot.layoutPriority(1)
                closeMosaicDot.layoutPriority(1)
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
        .reportChromeFrame(.statusBar, into: $chromeFrames))
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

                    actionRow(model.hostPlatform.adapt(String(localized: "Mac")), systemImage: model.hostPlatform == .mac ? "macbook" : "desktopcomputer") {
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
                        actionChip(String(localized: "Mode"), systemImage: "square.grid.2x2") {
                            showsModePicker = true
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
                            } else if let slowLabel = slowConnectionLabel {
                                Text(slowLabel)
                                    .font(.caption2.weight(.semibold))
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

                    Spacer(minLength: 0)
                    Image(systemName: "chevron.down")
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundStyle(.tertiary)
                }
                .padding(.leading, 16)
                .padding(.trailing, 20)
                .padding(.vertical, 8)
                // A fixed size: a pill that resized itself to the window's title would move the picture under a finger aiming at it, and a short title made it a small button.
                .frame(maxWidth: .infinity, alignment: .leading)
                .frame(height: 56)
                .contentShape(pillShape)
                .onTapGesture { expandStatusBar() }
                .transition(Self.pillContents)
            }
        }
        // Clipped to the shape, not the bounds: `.clipped()` left contents showing outside the rounded edge. It also covers mid-flight, since content is laid out at final size from the first frame of the spring.
        .clipShape(pillShape)
        .glassSurface(in: pillShape)
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
}
