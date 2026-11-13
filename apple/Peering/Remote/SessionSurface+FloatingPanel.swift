import PeeringKit
import RemoteCore
import SwiftUI
import UIKit

extension SessionSurface {
    @ViewBuilder
    /// `connectedWidth` is set when the panel is the upper half of the portrait tray: the tray draws the one glass, so the panel draws none and takes the dock's width.
    func floatingPanel(_ available: CGSize, isLandscape: Bool, connectedWidth: CGFloat? = nil) -> some View {
        // `alignment: .bottom` on every one of these, and it is load-bearing rather than tidy.
        // `maxHeight` makes a view *flexible* up to that height, so a panel whose contents are
        // shorter than the ceiling, the shortcuts panel nearly always, grows to the ceiling and
        // centres its contents inside it. Bottom-aligned, the frame is still the ceiling but the
        // panel sits at the bottom of it, which is where a panel belongs.
        if let panel = openPanel {
            // The panel's own height when its contents fit under the ceiling; the scrolling, ceiling-high one only when they do not.
            CeilingLayout(ceiling: ceiling(available, isLandscape)) {
                ViewThatFits(in: .vertical) {
                    panelBody(panel).fixedSize(horizontal: false, vertical: true)
                    panelBody(panel)
                }
            }
            .matchedGeometryEffect(id: "surface", in: floatingSurface)
            .modifier(PanelSurface(isConnected: connectedWidth != nil))
            .frame(width: connectedWidth, height: nil)
            .frame(maxWidth: connectedWidth == nil ? Self.panelWidth : nil)
            .modifier(PanelDragEffect(isConnected: connectedWidth != nil, drag: panelDragState))
            // Outside everything a drag moves: reported from inside, its frame changed on every touch sample and each write re-evaluated the whole screen.
            .reportChromeFrame(.panel, into: $chromeFrames)
            .modifier(PanelFollowsFinger(isConnected: connectedWidth != nil, drag: panelDragState))
            .transition(connectedWidth == nil ? .move(edge: .bottom).combined(with: .opacity) : Self.connectedPanelTransition)
        }
    }

    /// The panel's contents come up out of the dock through a blur, so they read as the glass opening rather than a card being placed.
    private static let connectedPanelTransition: AnyTransition = .modifier(
        active: PanelBlurReveal(amount: 1),
        identity: PanelBlurReveal(amount: 0)
    )

    private func panelBody(_ panel: Panel) -> AnyView {
        AnyView(VStack(spacing: 0) {
            panelHandle
            panelContent(panel)
                .frame(maxWidth: .infinity)
                .geometryGroup()
                .id(panel)
                .transition(.blurReplace(.downUp))
        })
    }

    /// Pulling down follows the finger; pulling up past the open position stretches with growing resistance, so the sheet gives a little and then holds.
    private static func resisted(_ travel: CGFloat) -> CGFloat {
        if travel >= 0 { return travel }
        let limit: CGFloat = 36
        let stretch = (1 - 1 / (-travel * 0.55 / limit + 1)) * limit
        return -stretch
    }

    /// Every panel has the same one: drag it down to put it away, which leaves the picture free to use.
    private var panelHandle: some View {
        Capsule()
            .fill(Color.white.opacity(0.32))
            .frame(width: 38, height: 5)
            .frame(maxWidth: .infinity)
            .frame(height: 20)
            .contentShape(Rectangle())
            .onTapGesture { withAnimation(Motion.settle) { openPanel = nil } }
            .gesture(
                DragGesture(minimumDistance: 4, coordinateSpace: .global)
                    .onChanged { drag in
                        // No animation: the panel must be exactly where the finger is.
                        var transaction = Transaction()
                        transaction.disablesAnimations = true
                        withTransaction(transaction) { panelDragState.translation = Self.resisted(drag.translation.height) }
                    }
                    .onEnded { drag in
                        let closes = drag.predictedEndTranslation.height > 90 || drag.translation.height > 60
                        if closes, panelDragState.naturalHeight > 0 {
                            // Carried the rest of the way shut, then removed with no second animation on top.
                            withAnimation(.spring(response: 0.34, dampingFraction: 0.9), completionCriteria: .logicallyComplete) {
                                panelDragState.translation = panelDragState.naturalHeight
                            } completion: {
                                var transaction = Transaction()
                                transaction.disablesAnimations = true
                                withTransaction(transaction) {
                                    openPanel = nil
                                    panelDragState.translation = 0
                                }
                            }
                        } else {
                            // A little spring on the way back, so letting go short of the threshold feels like a sheet settling.
                            withAnimation(.spring(response: 0.38, dampingFraction: 0.78)) {
                                panelDragState.translation = 0
                                if closes { openPanel = nil }
                            }
                        }
                    }
            )
            .accessibilityElement()
            .accessibilityLabel(String(localized: "Close panel", table: "Dictation"))
            .accessibilityAddTraits(.isButton)
            .accessibilityAction { withAnimation(Motion.settle) { openPanel = nil } }
    }

    /// Erased: the height-fitting wrapper holds this twice, and the four panels' types together would push the chrome's generic type past what the runtime's demangler can resolve.
    private func panelContent(_ panel: Panel) -> AnyView {
        switch panel {
        case .shortcuts:
            AnyView(shortcutsPanel)
        case .trackpad:
            // No top padding: the handle above already leaves the room, and a second margin made the sheet read as taller than the pad in it.
            AnyView(pointerPad.padding(.horizontal, 10).padding(.bottom, 10))
        case .clipboard:
            AnyView(ClipboardPanel(chromeFrames: $chromeFrames))
        case .sources:
            AnyView(SourcesPanel(
                chromeFrames: $chromeFrames,
                onSelect: closePanelAfterSelection,
                onReturnToMosaic: animateBackToMosaic
            ))
        case .settings:
            AnyView(SettingsPanel(chromeFrames: $chromeFrames) {
                withAnimation(Motion.settle) { openPanel = .sources }
            })
        }
    }

    static let panelWidth: CGFloat = 520

    /// One place, because two things ask: the panel opening, and a session coming up while the panel
    /// is already on screen. Neither host keeps these pictures for long, they are taken on demand
    /// and pruned against the sources the Mac is offering now, so a reconnect to a Mac that has
    /// been relaunched in between is a grid of outlines until something asks again.
    func stopWatchingSourcePictures() {
        model.send(.watchSourceThumbnails(false))
    }

    func askForSourcePictures() {
        guard openPanel == .sources else { return }
        model.send(.watchSourceThumbnails(true))
        if let info = model.catalog?.spaceInfo, SourcesPanel.showsDesktops(info) {
            model.send(.refreshSpacePreviews)
        }
    }

    static let desktopRefreshInterval: Duration = .seconds(4)

    /// **Not ``askForSourcePictures()``.** That one also asks for a photograph of every window the
    /// Mac is offering, which is a capture per window. Window pictures do not go stale while the
    /// panel is up unless something changes on the Mac, and every window event there invalidates
    /// them anyway; the desktops are the ones that change under the user, and they are what a tile
    /// in this grid is drawn from.
    func askForFreshDesktops() {
        guard openPanel == .sources else { return }
        guard let info = model.catalog?.spaceInfo, SourcesPanel.showsDesktops(info) else { return }
        model.send(.refreshSpacePreviews)
    }

    /// Shortcuts is exempt and always will be, whatever the setting says: its buttons are momentary
    /// key presses rather than choices, and a panel that shut after every keystroke would have to
    /// be reopened for the next one.
    func closePanelAfterSelection() {
        guard hidesPanelAfterSelect else { return }
        withAnimation(Motion.settle) { openPanel = nil }
    }
}

/// The panel's own glass and side margin, which the joined tray replaces with one surface for panel and dock together.
private struct PanelSurface: ViewModifier {
    let isConnected: Bool

    func body(content: Content) -> some View {
        if isConnected {
            content
        } else {
            content
                .glassSurface(in: RoundedRectangle(cornerRadius: 22, style: .continuous))
                .padding(.horizontal, 10)
        }
    }
}

private struct PanelBlurReveal: ViewModifier {
    /// 0 is settled, 1 is the hidden end of the transition.
    let amount: CGFloat

    func body(content: Content) -> some View {
        content
            .blur(radius: amount * 14)
            .opacity(1 - amount)
            .scaleEffect(1 - amount * 0.06, anchor: .bottom)
            .offset(y: amount * 28)
    }
}

/// Where the handle has dragged the panel, kept out of the screen's own state: a touch sample writes this many times a second, and held in `@State` on the screen each one re-evaluated the whole chrome. Only ``PanelDragEffect`` reads it, so only that re-evaluates.
@MainActor @Observable
final class PanelDragState {
    var translation: CGFloat = 0
    /// The panel's height at rest, measured while nothing is dragging it.
    var naturalHeight: CGFloat = 0
}

/// Joined to the dock, the contents ride down with the glass's top edge and are clipped at the panel's own bottom, where the dock begins: shut, they have gone into it, rather than been sliced off from above.
private struct PanelDragEffect: ViewModifier {
    let isConnected: Bool
    let drag: PanelDragState

    func body(content: Content) -> some View {
        if isConnected {
            let shift = min(max(drag.translation, 0), drag.naturalHeight)
            ZStack(alignment: .top) {
                content
                    .onGeometryChange(for: CGFloat.self) { $0.size.height } action: { height in
                        if drag.translation == 0 { drag.naturalHeight = height }
                    }
                    .offset(y: shift)
            }
            .clipped()
        } else {
            content
        }
    }
}

/// A panel on its own (landscape) follows the finger as a whole.
private struct PanelFollowsFinger: ViewModifier {
    let isConnected: Bool
    let drag: PanelDragState

    func body(content: Content) -> some View {
        if isConnected {
            content
        } else {
            let translation = drag.translation
            content
                .offset(y: translation)
                .transaction(value: translation) { $0.animation = nil }
        }
    }
}

/// The tray's glass, whose top edge follows the drag. The glass is redrawn in a new shape each frame rather than clipped, so its rim and highlight stay on the edge the finger is moving, and nothing is laid out again. Pulled up past rest, the surface grows above the tray a little. Its own small view so that only it reads the drag.
struct TrayGlass: View {
    let drag: PanelDragState
    let topRadius: CGFloat
    let bottomRadius: CGFloat

    var body: some View {
        let translation = drag.translation
        let cut = min(max(translation, 0), drag.naturalHeight)
        Color.clear
            .glassSurface(in: TrayShape(cut: cut, topRadius: topRadius, bottomRadius: bottomRadius))
            .padding(.top, min(translation, 0))
    }
}

/// The tray's rounded rectangle with `cut` taken off the top.
nonisolated struct TrayShape: InsettableShape {
    var cut: CGFloat
    var topRadius: CGFloat
    var bottomRadius: CGFloat
    var insetAmount: CGFloat = 0

    var animatableData: AnimatablePair<CGFloat, AnimatablePair<CGFloat, CGFloat>> {
        get { AnimatablePair(cut, AnimatablePair(topRadius, bottomRadius)) }
        set {
            cut = newValue.first
            topRadius = newValue.second.first
            bottomRadius = newValue.second.second
        }
    }

    func path(in rect: CGRect) -> Path {
        var area = rect.insetBy(dx: insetAmount, dy: insetAmount)
        area.origin.y += cut
        area.size.height = max(0, area.height - cut)
        return UnevenRoundedRectangle(
            topLeadingRadius: topRadius,
            bottomLeadingRadius: bottomRadius,
            bottomTrailingRadius: bottomRadius,
            topTrailingRadius: topRadius,
            style: .continuous
        ).path(in: area)
    }

    func inset(by amount: CGFloat) -> TrayShape {
        var inset = self
        inset.insetAmount += amount
        return inset
    }
}

/// Caps its child's height without growing it. `frame(maxHeight:)` cannot: a flexible frame takes the height it is offered up to the cap, so a short panel was stretched to the ceiling and its contents floated in the empty glass.
private struct CeilingLayout: Layout {
    let ceiling: CGFloat

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        guard let child = subviews.first else { return .zero }
        let size = child.sizeThatFits(ProposedViewSize(width: proposal.width, height: min(proposal.height ?? ceiling, ceiling)))
        return CGSize(width: size.width, height: min(size.height, ceiling))
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        subviews.first?.place(at: bounds.origin, anchor: .topLeading, proposal: ProposedViewSize(width: bounds.width, height: bounds.height))
    }
}
