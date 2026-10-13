import PeeringKit
import RemoteCore
import SwiftUI

extension RemoteScreen {
    static let dockIconSize: CGFloat = 42
    static let dockDesktopSize = CGSize(width: 54, height: 34)
    static let dockDesktopsWidth: CGFloat = 232

    var applicationDockItems: [CaptureSourceDescriptor] {
        model.catalog?.applications ?? []
    }

    var activeApplicationBundleID: String? {
        guard let id = model.activeSourceID,
              let descriptor = model.catalog?.all.first(where: { $0.id == id })
        else { return nil }
        return descriptor.bundleIdentifier
    }

    var applicationDockDisplay: SpaceDisplay? {
        guard let info = model.catalog?.spaceInfo, SourcesPanel.showsDesktops(info) else { return nil }
        let shown = model.catalog?.all.first { $0.id == model.activeSourceID }?.source
        if case .display(let displayID) = shown,
           let watched = info.displays.first(where: { $0.displayID == displayID }) {
            return watched
        }
        return info.displays.first
    }

    var applicationDockIsOffered: Bool {
        !applicationDockItems.isEmpty && openPanel == nil
    }

    @ViewBuilder
    var applicationDock: some View {
        if applicationDockIsOffered {
            VStack(spacing: 5) {
                if applicationDockIsUp {
                    applicationDockStrip
                        .transition(.move(edge: .bottom).combined(with: .opacity))
                }
                applicationDockHandle
            }
            .reportChromeFrame(.dock, into: $chromeFrames)
            .padding(.bottom, ChromeMetrics.edgeInset)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottom)
            // **On the screen's own bottom edge rather than on the safe area's, and the order of
            // these three lines is what says so.** The padding has to be *inside* the expansion:
            // written outside it, the padded view is laid out in the reduced region again and the
            // safe area comes back, which is what put this thirty points off the edge while it
            // looked correct. The picture runs to the edge in this orientation and so does this,
            // held off it by the same eight points the header hangs by at the top.
            .ignoresSafeArea(.container, edges: model.showKeyboard ? [] : .bottom)
        }
    }

    private var applicationDockStrip: some View {
        HStack(spacing: 0) {
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 3) {
                    ForEach(applicationDockItems) { application in
                        applicationDockItem(application)
                    }
                }
                .padding(.horizontal, 6)
                .padding(.vertical, 3)
            }
            .scrollBounceBehavior(.basedOnSize)

            if let display = applicationDockDisplay {
                Rectangle()
                    .fill(ColorPalette.ink.opacity(0.15))
                    .frame(width: 1, height: 26)
                    .padding(.horizontal, 5)

                applicationDockDesktops(display)
            }
        }
        // As wide as its contents until it runs out of room, and no wider. The cap is what keeps a
        // Mac running twenty applications from covering the screen: past it the two rows scroll.
        .frame(maxWidth: Self.panelWidth)
        .glassSurface(in: RoundedRectangle(cornerRadius: 16, style: .continuous))
        .gesture(dockDrag)
    }

    private func applicationDockItem(_ descriptor: CaptureSourceDescriptor) -> some View {
        let isOnScreen = descriptor.bundleIdentifier != nil
            && descriptor.bundleIdentifier == activeApplicationBundleID
        let windows = applicationWindows(of: descriptor)

        return Button {
            // The picture is already this source: asking again is a stream torn down and built
            // again for the same window, which the user pays for in black frames.
            if descriptor.id != model.activeSourceID {
                withAnimation(Motion.settle) { model.selectSource(descriptor) }
            }
            setApplicationDock(false)
        } label: {
            ApplicationIcon(
                data: descriptor.iconPNGData,
                fallback: "app",
                size: Self.dockIconSize
            )
            .overlay {
                RoundedRectangle(
                    cornerRadius: Self.dockIconSize * (11.0 / 42.0),
                    style: .continuous
                )
                .strokeBorder(isOnScreen ? ColorPalette.accent : .clear, lineWidth: 2)
            }
            .overlay(alignment: .topTrailing) {
                if windows.count > 1 {
                    Text("\(windows.count)")
                        .font(.system(size: 9, weight: .bold).monospacedDigit())
                        .foregroundStyle(ColorPalette.onInk)
                        .padding(.horizontal, 4)
                        .frame(minWidth: 14, minHeight: 14)
                        .background(ColorPalette.accent, in: Capsule())
                        .offset(x: 2, y: -2)
                }
            }
            .padding(2)
            .contentShape(Rectangle())
        }
        .buttonStyle(RailButtonStyle(scale: 0.88, haptic: true))
        .animation(Motion.tap, value: isOnScreen)
        .contextMenu {
            Section(descriptor.title) {
                if windows.isEmpty {
                    Text("No windows open")
                } else {
                    ForEach(windows) { window in
                        Button {
                            withAnimation(Motion.settle) { model.selectSource(window) }
                            setApplicationDock(false)
                        } label: {
                            Label(window.title, systemImage: "macwindow")
                        }
                    }
                }
            }
        }
        .accessibilityLabel(descriptor.title)
        .accessibilityHint("Shows this application on the Mac")
    }

    private func applicationDockDesktops(_ display: SpaceDisplay) -> some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 3) {
                // Offsets rather than `1...count`, which is an empty range when a display reports
                // nothing and traps on the way, and one added here rather than a number drawn
                // wrong: a desktop is numbered from one, which is what the Mac's own previews are
                // keyed by and what a switch asks for. Drawn from the offset, the first tile is a
                // desktop the Mac has never heard of.
                ForEach(0..<display.count, id: \.self) { offset in
                    applicationDockDesktop(display, index: offset + 1)
                }
            }
            .padding(.horizontal, 6)
            .padding(.vertical, 3)
        }
        .scrollBounceBehavior(.basedOnSize)
        .frame(maxWidth: Self.dockDesktopsWidth)
    }

    private func applicationDockDesktop(_ display: SpaceDisplay, index: Int) -> some View {
        let isShowing = model.activeSourceID == CaptureSource.display(display.displayID).stableID
        let isCurrent = display.current == index
        let isLive = isShowing && isCurrent

        return Button {
            if !isShowing { model.selectSource(.display(display.displayID)) }
            model.send(.switchToSpace(display: display.displayID, index: index))
            setApplicationDock(false)
        } label: {
            ZStack {
                ColorPalette.surface
                if let data = display.preview(for: index)?.jpegData,
                   let image = dockPreviews.image(
                       for: "\(display.displayID)-\(index)",
                       data: data
                   ) {
                    Image(uiImage: image)
                        .resizable()
                        .aspectRatio(contentMode: .fill)
                } else {
                    Image(systemName: "rectangle.dashed")
                        .font(.system(size: 12, weight: .medium))
                        .foregroundStyle(.tertiary)
                }
            }
            .frame(width: Self.dockDesktopSize.width, height: Self.dockDesktopSize.height)
            .clipShape(RoundedRectangle(cornerRadius: 6, style: .continuous))
            .overlay {
                RoundedRectangle(cornerRadius: 6, style: .continuous)
                    .strokeBorder(
                        isLive
                            ? ColorPalette.accent
                            : ColorPalette.ink.opacity(isCurrent ? 0.5 : 0.18),
                        lineWidth: isLive ? 2 : 1
                    )
            }
            .overlay(alignment: .bottomLeading) {
                Text("\(index)")
                    .font(.system(size: 9, weight: .semibold).monospacedDigit())
                    .foregroundStyle(ColorPalette.ink)
                    .padding(.horizontal, 3)
                    .frame(minWidth: 13, minHeight: 13)
                    .background(Color.black.opacity(0.55), in: Capsule())
                    .padding(2)
            }
        }
        .buttonStyle(RailButtonStyle(scale: 0.9, haptic: true))
        .animation(Motion.tap, value: isLive)
        .accessibilityLabel(
            isLive ? String(localized: "Desktop \(index), showing") : (isCurrent ? String(localized: "Desktop \(index), current") : String(localized: "Desktop \(index)"))
        )
        .accessibilityHint("Shows this desktop on the Mac")
    }

    private var applicationDockHandle: some View {
        HStack(spacing: 4) {
            Image(systemName: applicationDockIsUp ? "chevron.down" : "chevron.up")
                .font(.system(size: 9, weight: .semibold))
            Text("Dock")
                .font(.system(size: 10, weight: .medium))
        }
        .foregroundStyle(ColorPalette.ink.opacity(0.72))
        .padding(.horizontal, 12)
        .frame(height: 22)
        .glassSurface(in: Capsule())
        .frame(height: 30)
        .contentShape(Rectangle())
        .onTapGesture { setApplicationDock(!applicationDockIsUp) }
        .gesture(dockDrag)
        .animation(Motion.tap, value: applicationDockIsUp)
        .accessibilityLabel(
            applicationDockIsUp ? "Hide the dock" : "Show the dock"
        )
        .accessibilityAddTraits(.isButton)
    }

    func setApplicationDock(_ up: Bool) {
        guard up != applicationDockIsUp else { return }
        withAnimation(Motion.settle) { applicationDockIsUp = up }
    }

    private var dockDrag: some Gesture {
        DragGesture(minimumDistance: 10)
            .onEnded { value in
                guard abs(value.translation.height) > 24 else { return }
                setApplicationDock(value.translation.height < 0)
            }
    }

    private func applicationWindows(
        of descriptor: CaptureSourceDescriptor
    ) -> [CaptureSourceDescriptor] {
        let windows = model.catalog?.windows ?? []
        guard let bundle = descriptor.bundleIdentifier else {
            return windows.filter { $0.subtitle == descriptor.title }
        }
        return windows.filter { $0.bundleIdentifier == bundle }
    }
}
