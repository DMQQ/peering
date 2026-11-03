import PeeringKit
import RemoteCore
import SwiftUI
import UIKit

extension RemoteScreen {
    @ViewBuilder
    func floatingPanel(_ available: CGSize, isLandscape: Bool) -> some View {
        // `alignment: .bottom` on every one of these, and it is load-bearing rather than tidy.
        // `maxHeight` makes a view *flexible* up to that height, so a panel whose contents are
        // shorter than the ceiling, the shortcuts panel nearly always, grows to the ceiling and
        // centres its contents inside it. Bottom-aligned, the frame is still the ceiling but the
        // panel sits at the bottom of it, which is where a panel belongs.
        if let panel = openPanel {
            ZStack(alignment: .bottom) {
                VStack(spacing: 0) {
                    panelHandle
                    panelContent(panel)
                        .frame(maxWidth: .infinity)
                        .geometryGroup()
                        .id(panel)
                        .transition(.blurReplace(.downUp))
                }
            }
            .matchedGeometryEffect(id: "surface", in: floatingSurface)
            .glassSurface(in: RoundedRectangle(cornerRadius: 22, style: .continuous))
            .padding(.horizontal, 10)
            .reportChromeFrame(.panel, into: $chromeFrames)
            .frame(maxWidth: Self.panelWidth, maxHeight: ceiling(available, isLandscape), alignment: .bottom)
            .offset(y: panelDrag)
            .transaction(value: panelDrag) { $0.animation = nil }
            .transition(.move(edge: .bottom).combined(with: .opacity))
        }
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
                    .onChanged { drag in panelDrag = max(0, drag.translation.height * 0.8) }
                    .onEnded { drag in
                        let closes = drag.predictedEndTranslation.height > 90 || drag.translation.height > 60
                        withAnimation(Motion.settle) {
                            panelDrag = 0
                            if closes { openPanel = nil }
                        }
                    }
            )
            .accessibilityElement()
            .accessibilityLabel(String(localized: "Close panel", table: "Dictation"))
            .accessibilityAddTraits(.isButton)
            .accessibilityAction { withAnimation(Motion.settle) { openPanel = nil } }
    }

    @ViewBuilder
    private func panelContent(_ panel: Panel) -> some View {
        switch panel {
        case .shortcuts:
            shortcutsPanel
        case .clipboard:
            ClipboardPanel(chromeFrames: $chromeFrames)
        case .sources:
            SourcesPanel(
                chromeFrames: $chromeFrames,
                onSelect: closePanelAfterSelection,
                onReturnToMosaic: animateBackToMosaic
            )
        case .settings:
            SettingsPanel(chromeFrames: $chromeFrames) {
                withAnimation(Motion.settle) { openPanel = .sources }
            }
        }
    }

    static let panelWidth: CGFloat = 520

    /// One place, because two things ask: the panel opening, and a session coming up while the panel
    /// is already on screen. Neither host keeps these pictures for long, they are taken on demand
    /// and pruned against the sources the Mac is offering now, so a reconnect to a Mac that has
    /// been relaunched in between is a grid of outlines until something asks again.
    func stopWatchingSourcePictures() {
        if model.hostSupportsSourceThumbnails {
            model.send(.watchSourceThumbnails(false))
        }
    }

    func askForSourcePictures() {
        guard openPanel == .sources else { return }
        if model.hostSupportsSourceThumbnails {
            model.send(.watchSourceThumbnails(true))
        }
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
