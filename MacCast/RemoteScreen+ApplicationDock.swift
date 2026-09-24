import MacCastKit
import RemoteCore
import SwiftUI

/// The Mac's running applications and the desktops behind them, on a handle at the bottom of a
/// landscape screen.
///
/// **Landscape only, and that is what pays for it.** A phone held upright gives the picture every
/// point it can; held sideways the picture is as tall as the screen and the band along the bottom
/// is the cheapest place on it to keep something.
///
/// **Down rather than out, and that is what pays for the rest.** The applications are the one thing
/// on this screen a user reaches for *between* two of the things they are already doing, so it has
/// to be one gesture away; but it is also the one piece of chrome whose contents are pictures, so
/// left standing it would take a row off the picture permanently to serve something used for a
/// second at a time. It is a handle the size of a fingertip until it is asked for.
///
/// **The panel is still where a source is found.** It draws a picture of every window, the desktops
/// of every screen and the applications that are installed, and a strip this tall cannot do that.
/// What this does is the Mac's own Dock's job, one tap deep: what is running, and which desktop the
/// screen being watched is on.
extension RemoteScreen {
    /// One icon's edge.
    ///
    /// As large as the row can carry: what the strip is made of is other applications' artwork,
    /// and artwork a finger cannot tell apart is a row of coloured squares.
    static let dockIconSize: CGFloat = 42
    /// One desktop's picture, and how much of the strip the desktops may take.
    static let dockDesktopSize = CGSize(width: 54, height: 34)
    static let dockDesktopsWidth: CGFloat = 232

    /// The applications the strip is made of, which is whatever the Mac last said was running.
    var applicationDockItems: [CaptureSourceDescriptor] {
        model.catalog?.applications ?? []
    }

    /// The bundle identifier of whatever is being shown, when it belongs to an application.
    ///
    /// A window's row carries its owning application's identifier, so a phone looking at one window
    /// marks that application rather than nothing: a captured window is that application as far as
    /// this dock is concerned. Nil for a display, and nil for an arrangement, which belong to no
    /// application at all.
    var activeApplicationBundleID: String? {
        guard let id = model.activeSourceID,
              let descriptor = model.catalog?.all.first(where: { $0.id == id })
        else { return nil }
        return descriptor.bundleIdentifier
    }

    /// The screen whose desktops the strip shows, when there is a choice to show.
    ///
    /// The one being watched, and the first one otherwise: a window is wherever it is and has no
    /// desktops of its own, and a row of pictures of a screen nobody is looking at would be a row
    /// of somewhere else. Gated by the panel's own rule, which is also what keeps a Mac with one
    /// desktop from being offered a row of one.
    var applicationDockDisplay: SpaceDisplay? {
        guard let info = model.catalog?.spaceInfo, SourcesPanel.showsDesktops(info) else { return nil }
        let shown = model.catalog?.all.first { $0.id == model.activeSourceID }?.source
        if case .display(let displayID) = shown,
           let watched = info.displays.first(where: { $0.displayID == displayID }) {
            return watched
        }
        return info.displays.first
    }

    /// Whether the handle is drawn at all.
    ///
    /// Not while a panel is open: the panel is the fuller answer to the same question, it ends
    /// where this begins, and a handle hanging below it would be a second way to ask for what is
    /// already on screen.
    var applicationDockIsOffered: Bool {
        !applicationDockItems.isEmpty && openPanel == nil
    }

    /// The handle, and the strip above it when it is up.
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
            // Reported as one region, the pair of them, because the handle and the strip are the
            // same control in two states and the canvas must take touches in neither. Measured
            // before the frame below stretches this to the screen, so what is reported is the
            // control rather than the whole bottom edge.
            .reportChromeFrame(.dock, into: $chromeFrames)
            .padding(.bottom, ChromeMetrics.edgeInset)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottom)
            // **On the screen's own bottom edge rather than on the safe area's, and the order of
            // these three lines is what says so.** The padding has to be *inside* the expansion:
            // written outside it, the padded view is laid out in the reduced region again and the
            // safe area comes back, which is what put this thirty points off the edge while it
            // looked correct. The picture runs to the edge in this orientation and so does this,
            // held off it by the same eight points the header hangs by at the top.
            //
            // Not while the keyboard bar is up: that bar is a safe area inset of its own, and a
            // dock expanded past it would be sitting under it, where nothing can be pressed.
            .ignoresSafeArea(.container, edges: model.showKeyboard ? [] : .bottom)
        }
    }

    /// The applications, and the desktops of the screen being watched, at the trailing end.
    private var applicationDockStrip: some View {
        HStack(spacing: 0) {
            // Tight, and the icons are what the height is for: a strip padded until it looks calm
            // is a strip taking a row off the picture to hold six small pictures in it.
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
                // Between the two kinds of thing the strip holds, because they are two kinds: one
                // is what is running on the Mac and the other is where this screen is looking.
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

    /// One application: its icon, and a ring around it when its picture is the one on screen.
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
            // The one mark, and the same accent every other "this is the one" mark in the app
            // uses. Told apart from the icon's own artwork by being a ring rather than a fill:
            // what is inside it is a picture nobody here drew.
            .overlay {
                RoundedRectangle(
                    cornerRadius: Self.dockIconSize * (11.0 / 42.0),
                    style: .continuous
                )
                .strokeBorder(isOnScreen ? ColorPalette.accent : .clear, lineWidth: 2)
            }
            // **How many windows it has, when that is worth saying.** One is the ordinary state of
            // a running application and a badge on every icon would be a row of ones; past that it
            // is the number that says whether the hold below is worth taking, which is the only
            // other thing an icon here can tell you.
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
        // Felt as well as seen, which is what the session chrome does with its own buttons: this
        // one's work happens on the other machine, so it answers here or nowhere.
        .buttonStyle(RailButtonStyle(scale: 0.88, haptic: true))
        .animation(Motion.tap, value: isOnScreen)
        // **The windows, on a hold.** One tap is the whole of what the strip promises; an
        // application with three windows of its own is where the panel used to be the only answer,
        // and this is the shortcut past it.
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

    /// The desktops of one screen, in order, as the pictures they are.
    ///
    /// **A picture rather than a number**, for the reason the panel gives: the question being asked
    /// is "which one had my browser on it", and a number cannot answer that. The number is drawn on
    /// the picture here rather than under it, because a caption is a second line and this strip is
    /// one.
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
        // Two facts, as in the panel: where that screen is, and where this phone is looking. They
        // are the same tile only while the phone is on that screen at all.
        let isCurrent = display.current == index
        let isLive = isShowing && isCurrent

        return Button {
            // The picture follows the desktop, and it is asked for first: a strip that moved the
            // Mac's screen and left the phone on another one would be showing the desktop that was
            // left.
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
                    // An empty tile is the truth: this desktop has not been on screen since the
                    // host started, so there is no picture of it to show.
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
            // On the picture, at the corner the panel draws its own numbers in.
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
            isLive ? "Desktop \(index), showing" : (isCurrent ? "Desktop \(index), current" : "Desktop \(index)")
        )
        .accessibilityHint("Shows this desktop on the Mac")
    }

    /// The handle: a tap opens the strip and closes it, and so does a drag in either direction.
    ///
    /// **Named, and that is the difference between this and the bare line it was.** A finger-thick
    /// capsule at the bottom of the screen is a shape nobody can read: it could be a resize grip, a
    /// page indicator, or the home indicator's own neighbour. The word is the app's own for the row
    /// of applications, and the chevron says which way it goes, which is the shape the portrait
    /// dock's own toggle already taught.
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
        // A target the height of a fingertip around a shape a third of that.
        .frame(height: 30)
        .contentShape(Rectangle())
        .onTapGesture { setApplicationDock(!applicationDockIsUp) }
        .gesture(dockDrag)
        .animation(Motion.tap, value: applicationDockIsUp)
        // No haptic: this one answers on the screen it was pressed on, which is the rule the button
        // style's own note gives.
        .accessibilityLabel(
            applicationDockIsUp ? "Hide the dock" : "Show the dock"
        )
        .accessibilityAddTraits(.isButton)
    }

    /// Opens or closes the strip, from every door that does it: the handle, the drag, and the pick.
    func setApplicationDock(_ up: Bool) {
        guard up != applicationDockIsUp else { return }
        withAnimation(Motion.settle) { applicationDockIsUp = up }
    }

    /// The one movement the handle and the strip have: up opens, down closes.
    private var dockDrag: some Gesture {
        DragGesture(minimumDistance: 10)
            .onEnded { value in
                guard abs(value.translation.height) > 24 else { return }
                setApplicationDock(value.translation.height < 0)
            }
    }

    /// The windows one application owns, as the catalogue lists them.
    ///
    /// Matched by bundle identifier, which an application's row and each of its windows carry, and
    /// by name only for a process that has none: the catalogue names such a row by its process
    /// name, and its windows are filed under it the same way.
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
