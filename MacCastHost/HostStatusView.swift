import AppKit
import CoreImage
import CoreImage.CIFilterBuiltins
import RemoteCore
import SwiftUI

/// The host's window: whether it is reachable, whether it has permission to do its job,
/// and the pairing code when a client is asking to be trusted.
/// What the window is showing.
///
/// A sidebar rather than one long scroll, because the window has grown two kinds of content
/// that want different things: what is happening *now* — the picture, who is attached — and
/// what can be configured or looked up, which is reference material that gets in the way until
/// it is wanted. `overview` is first and is the default, so the answer to "is someone on my
/// Mac" costs nothing.
enum HostSection: String, CaseIterable, Identifiable {
    case overview
    case sessions
    case privacy
    case settings
    case about

    var id: String { rawValue }

    var title: String {
        switch self {
        case .overview: return "Overview"
        case .sessions: return "Sessions"
        case .privacy: return "Privacy"
        case .settings: return "Settings"
        case .about: return "About"
        }
    }

    var symbol: String {
        switch self {
        case .overview: return "rectangle.connected.to.line.below"
        case .sessions: return "clock.arrow.circlepath"
        case .privacy: return "lock.shield"
        case .settings: return "gearshape"
        case .about: return "info.circle"
        }
    }
}

struct HostStatusView: View {
    @Environment(HostModel.self) private var model
    @State private var section: HostSection = .overview

    /// The last still of what the connected device is seeing.
    ///
    /// Held by the view rather than the model because it is only wanted while this window is
    /// on screen — the task below is cancelled with the view, which is what stops a closed or
    /// hidden window taking a screenshot of this Mac every couple of seconds.
    @State private var preview: CGImage?

    /// What is in the port field while it is being edited.
    ///
    /// A draft rather than a binding to the model, because the model's setter restarts the
    /// listener: bound directly, every keystroke would tear down the server and start it again.
    /// The value is committed on Return or when the field loses focus, and reverted if it is not
    /// a usable port — a field that silently keeps a number the host is not listening on is worse
    /// than one that puts the real number back.
    @State private var portDraft = ""
    @FocusState private var portFocused: Bool
    @State private var forgetDevice: (id: String, name: String)?
    @State private var hoveredDeviceID: String?
    @State private var hoveredSection: HostSection?
    @State private var heroHovered = false

    /// How much room the pane has, measured rather than assumed.
    ///
    /// The picture's height is derived from it — see `previewHeight` — so the frame it is drawn
    /// in is always the shape of what is being sent rather than a strip with letterbox bars
    /// above and below it.
    @State private var paneWidth: CGFloat = 0

    /// The pane's own inset from the window edge.
    ///
    /// Named because the picture's height is computed from the width this leaves: a number in two
    /// places is a picture that stops fitting the frame it is drawn in.
    private static let paneInset: CGFloat = 26

    var body: some View {
        NavigationSplitView {
            sidebar
                .navigationSplitViewColumnWidth(min: 190, ideal: 210, max: 250)
        } detail: {
            ZStack {
                HostPalette.backdrop.ignoresSafeArea()
                HostPalette.stageLight.ignoresSafeArea()

                ScrollView {
                    VStack(alignment: .leading, spacing: 24) {
                        // Above the pane rather than inside one. A pairing request is the only
                        // thing in this window that needs an answer, and burying it in a
                        // section the user is not looking at is how a phone sits at "waiting
                        // for you to compare the digits" with nobody comparing them.
                        if model.pairing != nil || model.lastOutcome != nil {
                            pairingSection
                        }

                        pane
                    }
                    .padding(.horizontal, Self.paneInset)
                    .padding(.top, 22)
                    .padding(.bottom, 28)
                    // The pane is only as wide as its widest row, and a scroll view centres
                    // what it is given. Overview looked right by accident — the preview pane
                    // asks for the full width — while a pane holding one short line of text
                    // floated in the middle of the window.
                    .frame(maxWidth: .infinity, alignment: .leading)
                    // Measured rather than assumed, and only the width is kept: the picture's
                    // height follows from it, so feeding the height back in would be asking the
                    // layout to solve itself. The width does not depend on the height, so this
                    // settles on the first pass and only moves when the window does.
                    .onGeometryChange(for: CGFloat.self) { $0.size.width } action: { width in
                        if abs(width - paneWidth) > 1 { paneWidth = width }
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
        // The sidebar column and the titlebar are two more surfaces the system paints for us, and
        // both default to a material over the window's own background — which on this window is
        // the grey the palette exists to get away from. Filling the window with the stage behind
        // the split view and pinning the toolbar to it leaves nothing drawing its own grey.
        .background(HostPalette.backdrop)
        .toolbarBackground(HostPalette.backdrop, for: .windowToolbar)
        // Ink, not the accent, and the difference is the whole reason this window reads as one
        // object rather than as a settings panel: a window-wide accent tint paints every button
        // the system draws for us, so `Forget all` and `Copy all` and two segmented pickers all
        // arrive blue, and the one blue that is supposed to mean something is somewhere in that
        // crowd. Left monochrome, the accent is spent on exactly two things — the row you are on
        // and the button that starts sharing — and both are things you look for.
        //
        // It is also what fixes a destructive button drawing in the colour that means "press me".
        .tint(HostPalette.controlTint)
        // The floor a Mac window for this job should never go under, and the size it wants to be.
        // The pane is only ever as wide as its widest row, so a window narrowed past the floor
        // starts clipping sentences rather than reflowing them.
        //
        // The ideal is load-bearing rather than decorative: `windowResizability(.contentSize)`
        // sizes the window to what its content asks for, and a content that only states a minimum
        // gets the minimum — which is how this opened at 900 wide with `defaultSize` set to 1200.
        // `defaultSize` is the first frame a window is ever given; the ideal is what it keeps
        // coming back to.
        .frame(minWidth: 900, idealWidth: 1200, minHeight: 620, idealHeight: 870)
        .task { model.start() }
        // Keyed on the source, so a client switching to another screen refreshes the picture at
        // once instead of showing the old one until the next tick. Two seconds is chosen against
        // what the picture is for: it is here to answer "what can they see", and a still that is
        // a second old answers that as well as a live one, for a fraction of the work.
        .task(id: model.capturingSource) {
            while !Task.isCancelled {
                let shot = await model.snapshot()
                guard !Task.isCancelled else { return }
                preview = shot
                try? await Task.sleep(for: .seconds(2))
            }
        }
        .confirmationDialog(
            "Forget \(forgetDevice?.name ?? "this iPhone")?",
            isPresented: Binding(
                get: { forgetDevice != nil },
                set: { if !$0 { forgetDevice = nil } }
            ),
            titleVisibility: .visible
        ) {
            Button("Forget", role: .destructive) {
                guard let target = forgetDevice else { return }
                model.unpair(clientID: target.id)
                forgetDevice = nil
            }
            Button("Cancel", role: .cancel) { forgetDevice = nil }
        } message: {
            Text("This phone will be disconnected and must pair again before it can control this Mac.")
        }
    }

    // MARK: - Status

    // MARK: - Sidebar

    /// The rail of sections, drawn here rather than handed to a sidebar `List`.
    ///
    /// A source-list `List` looks like the natural thing for five rows and was the first thing
    /// this window used, and it has one behaviour that cannot be argued with: it paints every row's
    /// symbol with the accent colour, and setting a `foregroundStyle` on the `Label` does not stop
    /// it. Five blue glyphs under one blue selection is the whole window's worth of accent spent
    /// before anything has happened, and the colour stops meaning "you are here" when it is also
    /// what the row below it means, and the row below that.
    ///
    /// So the rows are buttons. What that gives up is the arrow-key walking a source list does for
    /// free; what it buys is the ink staying ink, a selection that is a shape we chose, and
    /// ⌘1–⌘5 — which is a shorter path to any of these panes than arrowing to it ever was.
    private var sidebar: some View {
        VStack(spacing: 0) {
            sidebarHeader
            Divider().opacity(0.45)
            VStack(spacing: 2) {
                ForEach(Array(HostSection.allCases.enumerated()), id: \.element) { index, item in
                    sidebarRow(item)
                        .keyboardShortcut(KeyEquivalent(Character("\(index + 1)")), modifiers: .command)
                }
            }
            .padding(.horizontal, 8)
            .padding(.vertical, 8)
            Spacer(minLength: 0)
        }
        .background(HostPalette.backdrop)
    }

    /// One section. Selection is a fill rather than a tint, which is what the phone's rail does
    /// and the reason it does it: at arm's length a coloured glyph is hard to find, and a coloured
    /// shape is not.
    private func sidebarRow(_ item: HostSection) -> some View {
        let isSelected = section == item
        return Button {
            withAnimation(HostMotion.state) { section = item }
        } label: {
            HStack(spacing: 9) {
                Image(systemName: item.symbol)
                    .font(.system(size: 13, weight: .medium))
                    .frame(width: 18)
                Text(item.title)
                    .font(.system(size: 13, weight: isSelected ? .semibold : .regular))
                Spacer(minLength: 0)
            }
            .foregroundStyle(isSelected ? HostPalette.ink : HostPalette.muted)
            .padding(.horizontal, 9)
            .frame(height: 32)
            .background(
                isSelected
                    ? AnyShapeStyle(HostPalette.accent)
                    : AnyShapeStyle(hoveredSection == item ? HostPalette.raised : .clear),
                in: RoundedRectangle(cornerRadius: HostPalette.controlRadius, style: .continuous)
            )
            .contentShape(RoundedRectangle(cornerRadius: HostPalette.controlRadius, style: .continuous))
        }
        .buttonStyle(.plain)
        .onHover { hovering in hoveredSection = hovering ? item : nil }
        .accessibilityAddTraits(isSelected ? [.isSelected] : [])
    }

    /// The one part of the window that is visible whatever pane is showing.
    ///
    /// The app's own icon rather than an SF Symbol: this is the thing in the Dock, and matching
    /// it is what makes the window read as *this app* rather than as a settings panel that
    /// happens to have a status line. The state is carried by the sentence below it, which is
    /// the part a symbol cannot say.
    private var sidebarHeader: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 10) {
                Image(nsImage: NSApplication.shared.applicationIconImage)
                    .resizable()
                    .frame(width: 38, height: 38)
                    .shadow(color: Color.black.opacity(0.16), radius: 7, y: 3)
                    .accessibilityHidden(true)

                VStack(alignment: .leading, spacing: 1) {
                    Text("Peering")
                        .font(.system(size: 17, weight: .semibold, design: .rounded))
                    Text(model.deviceName)
                        .font(.caption)
                        .foregroundStyle(HostPalette.muted)
                        .lineLimit(1)
                }

                Spacer(minLength: 0)
            }

            // The sentence can outrun the column — "Connected — Damian's iPhone" is most of it
            // — so it truncates and carries the whole thing as a tooltip.
            //
            // One fact, said once. This was a coloured dot, coloured text, a tinted fill and a
            // tinted border, which is four marks for a state that has one value; at that point
            // the colour stops meaning anything and the pill just looks loud. The dot carries the
            // state, the sentence stays legible ink, and the pill itself is only a shape.
            HStack(spacing: 7) {
                Circle()
                    .fill(statusColor)
                    .frame(width: 7, height: 7)
                    .shadow(color: statusColor.opacity(0.6), radius: 4)
                Text(statusText)
                    .font(.caption.weight(.medium))
                    .foregroundStyle(model.connectedClients.isEmpty ? HostPalette.muted : HostPalette.ink)
                    .lineLimit(1)
            }
            .padding(.horizontal, 9)
            .frame(height: 24)
            .background(HostPalette.raised, in: Capsule())
            .overlay { Capsule().strokeBorder(HostPalette.hairline, lineWidth: 1) }
            .help(statusText)

            // The frame goes on the label, not the button. A bordered button sizes itself to
            // its label, so widening the button only pads the space around it — the control
            // stays the size of the word and sits in the middle of the column.
            //
            // Big, and it is the only filled control in the app. Both are deliberate. This is
            // the one thing the whole window exists to offer, and it used to be a small grey
            // word in the middle of a column — the least prominent thing on a screen whose only
            // question is whether the Mac is being shared. Everything else here is ink on a
            // surface and stays that way; this is the exception that earns its fill.
            //
            // The same blue the phone uses for the one control it marks, rather than the Mac's
            // own highlight colour, so the two apps agree about what "press this" looks like.
            // Quiet when it stops: the two states are not equals, and one of them is how you
            // put it down — see `HostHostingButtonStyle`.
            Button {
                model.status.isListening ? model.stop() : model.start()
            } label: {
                Text(model.status.isListening ? "Stop" : "Start")
                    .frame(maxWidth: .infinity)
                    .frame(height: 34)
            }
            .buttonStyle(HostHostingButtonStyle(isHosting: model.status.isListening))
            .animation(HostMotion.state, value: model.status.isListening)

            Text("Port \(model.boundPort) · protocol v\(ProtocolInfo.version)")
                .font(.caption2.monospacedDigit())
                .foregroundStyle(HostPalette.faint)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 14)
    }

    // MARK: - Detail

    @ViewBuilder
    private var pane: some View {
        switch section {
        case .overview:
            // The picture first, then how to get here, then the record. The picture is what the
            // window is for and it is also the thing that is *happening* — a Mac with a phone on
            // it should open onto the session, not onto instructions for starting one. The hints
            // sit directly under it, which is where someone who is looking for them will look
            // once they have seen the top of the window, and they withdraw on their own the
            // moment a device attaches — see `connectSection`.
            VStack(alignment: .leading, spacing: 24) {
                nowShowingSection
                connectSection
                overviewLowerDeck
            }
        case .sessions:
            sessionsSection
        case .privacy:
            VStack(alignment: .leading, spacing: 24) {
                permissionsSection
                privacyNote
            }
        case .settings:
            settingsSection
        case .about:
            aboutSection
        }
    }

    // MARK: - Connect

    /// How a phone gets here — shown only while nothing is attached.
    ///
    /// The rest of this pane answers questions about a device that is already connected: what it
    /// is looking at, when it arrived, what it has been doing. Open the window on an idle Mac and
    /// every one of those is an answer to a question nobody has asked yet, which is what made
    /// this screen read as a single empty panel. This is the question to answer for a Mac that
    /// nobody has reached yet, and the only part of this pane that has anything to say then.
    ///
    /// It sits under the picture rather than above it. Instructions at the top of a window push
    /// the actual subject down out of sight, and this is a window whose subject arrives on its
    /// own — but the panel still reads second, which is where someone who is stuck will look.
    ///
    /// Withdrawn as soon as something connects, because then the answers below are the ones
    /// being looked for.
    @ViewBuilder
    private var connectSection: some View {
        if model.connectedClients.isEmpty {
            VStack(alignment: .leading, spacing: 12) {
                sectionHeading(
                    "Connect",
                    detail: model.status.isListening
                        ? "This Mac is available on your network."
                        : "Press Start to make this Mac available."
                )

                VStack(spacing: 0) {
                    connectRow(
                        symbol: "wifi",
                        title: "On the same network",
                        detail: "Open Peering on your iPhone. It finds this Mac by itself, and shows a code to confirm the first time."
                    )
                    Divider().padding(.leading, 44)
                    connectRow(
                        symbol: "number",
                        title: "By address",
                        detail: "If discovery is blocked where you are, enter this Mac's address and port \(model.boundPort) by hand."
                    )
                    Divider().padding(.leading, 44)
                    connectRow(
                        symbol: "globe",
                        title: "From anywhere",
                        detail: "Once paired, this Mac stays reachable through the relay even on a different network."
                    )
                }
                .hostPanel()
            }
        }
    }

    private func connectRow(symbol: String, title: String, detail: String) -> some View {
        HStack(alignment: .top, spacing: 12) {
            Image(systemName: symbol)
                .font(.system(size: 15, weight: .medium))
                .foregroundStyle(HostPalette.muted)
                .frame(width: 26, height: 26)

            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .font(.subheadline.weight(.medium))
                Text(detail)
                    .font(.caption)
                    .foregroundStyle(HostPalette.muted)
                    .fixedSize(horizontal: false, vertical: true)
            }

            Spacer(minLength: 0)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 12)
    }

    // MARK: - Pairing

    @ViewBuilder
    private var pairingSection: some View {
        if let pairing = model.pairing {
            HStack(spacing: 24) {
                VStack(alignment: .leading, spacing: 12) {
                    Label("Pair a new iPhone", systemImage: "iphone.and.arrow.forward")
                        .font(.title3.weight(.semibold))

                    Text("Scan this code with Peering, or enter the six digits on \(pairing.clientName).")
                        .font(.callout)
                        .foregroundStyle(HostPalette.muted)
                        .fixedSize(horizontal: false, vertical: true)

                    Text(formatted(pairing.code))
                        .font(.system(size: 42, weight: .semibold, design: .monospaced))
                        .tracking(2)
                        .textSelection(.enabled)

                    Label("Only pair a device you recognize.", systemImage: "lock.fill")
                        .font(.caption)
                        .foregroundStyle(HostPalette.muted)
                }

                Spacer(minLength: 20)

                if let image = qrCode(for: pairing.code) {
                    Image(nsImage: image)
                        .interpolation(.none)
                        .resizable()
                        .frame(width: 126, height: 126)
                        .padding(10)
                        .background(.white, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
                        .accessibilityLabel("Pairing QR code")
                }
            }
            .priorityPanel()
        } else if let outcome = model.lastOutcome {
            HStack(spacing: 12) {
                Image(systemName: outcome.accepted ? "checkmark.circle.fill" : "xmark.circle.fill")
                    .font(.title2)
                    .foregroundStyle(outcome.accepted ? HostPalette.ink : HostPalette.muted)
                VStack(alignment: .leading, spacing: 2) {
                    Text(outcome.accepted ? "Device paired" : "Pairing cancelled")
                        .font(.headline)
                    Text(outcome.accepted
                         ? "\(outcome.clientName) can now reconnect automatically."
                         : "\(outcome.clientName) was not added to trusted devices.")
                        .font(.caption)
                        .foregroundStyle(HostPalette.muted)
                }
            }
            .padding(.vertical, 2)
        }
    }

    // MARK: - Setup

    private var permissionsSection: some View {
        VStack(alignment: .leading, spacing: 14) {
            sectionHeading("Mac access", detail: "Peering needs both permissions to stream and control this Mac.")

            VStack(spacing: 0) {
                permissionRow(
                    title: "Accessibility",
                    detail: "Clicks and keyboard input",
                    icon: "cursorarrow.click.2",
                    granted: model.permissions.accessibilityGranted,
                    request: model.permissions.requestAccessibility,
                    openSettings: model.permissions.openAccessibilitySettings
                )
                Divider().padding(.leading, 42)
                permissionRow(
                    title: "Screen Recording",
                    detail: "Live picture on your iPhone",
                    icon: "rectangle.dashed.badge.record",
                    granted: model.permissions.screenRecordingGranted,
                    request: model.permissions.requestScreenRecording,
                    openSettings: model.permissions.openScreenRecordingSettings
                )
            }
            .hostPanel()

            HStack(spacing: 8) {
                Button("Check again") { model.refreshPermissions() }
                    .controlSize(.small)
                Text("Restart Peering after changing a permission.")
                    .font(.caption)
                    .foregroundStyle(HostPalette.faint)
            }
        }
    }

    private func permissionRow(
        title: String,
        detail: String,
        icon: String,
        granted: Bool,
        request: @escaping () -> Void,
        openSettings: @escaping () -> Void
    ) -> some View {
        HStack(spacing: 12) {
            Image(systemName: icon)
                .font(.system(size: 16, weight: .medium))
                .foregroundStyle(granted ? HostPalette.ink : HostPalette.muted)
                .frame(width: 26, height: 26)

            VStack(alignment: .leading, spacing: 2) {
                Text(title).font(.subheadline.weight(.medium))
                Text(detail).font(.caption).foregroundStyle(HostPalette.muted)
            }

            Spacer(minLength: 12)

            if granted {
                Label("Allowed", systemImage: "checkmark")
                    .font(.caption.weight(.medium))
                    .foregroundStyle(HostPalette.ink)
            } else {
                Button("Allow", action: request).controlSize(.small)
                Button("Settings", action: openSettings).controlSize(.small)
            }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 12)
    }

    // MARK: - Settings

    private var settingsSection: some View {
        VStack(alignment: .leading, spacing: 14) {
            sectionHeading("Settings", detail: "Options for this Mac host.")

            VStack(spacing: 0) {
                HStack(spacing: 12) {
                    Image(systemName: "moon.zzz")
                        .font(.system(size: 16, weight: .medium))
                        .foregroundStyle(model.preventLidCloseSleep ? HostPalette.ink : HostPalette.muted)
                        .frame(width: 26, height: 26)

                    VStack(alignment: .leading, spacing: 2) {
                        Text("Keep Mac awake")
                            .font(.subheadline.weight(.medium))
                        Text("Prevents idle system and display sleep immediately; macOS shows no permission prompt. Closing the lid still follows macOS clamshell and power rules. Lifted automatically when Peering quits.")
                            .font(.caption)
                            .foregroundStyle(HostPalette.muted)
                            .fixedSize(horizontal: false, vertical: true)
                    }

                    Spacer(minLength: 12)

                    Toggle("", isOn: Binding(
                        get: { model.preventLidCloseSleep },
                        set: { model.setPreventLidCloseSleep($0) }
                    ))
                    .labelsHidden()
                    .toggleStyle(.switch)
                    .controlSize(.small)
                }
                .padding(.horizontal, 14)
                .padding(.vertical, 12)

                Divider().padding(.leading, 52)

                clientPointerRow

                Divider().padding(.leading, 52)

                captureResolutionRow

                Divider().padding(.leading, 52)

                frameRateRow

                Divider().padding(.leading, 52)

                codecRow

                Divider().padding(.leading, 52)

                portRow
            }
            .hostPanel()
        }
    }

    /// Pointer rendering belongs to the client. Keeping this visible explains why the cursor is
    /// absent from screenshots while avoiding a setting that no longer affects the stream.
    private var clientPointerRow: some View {
        HStack(spacing: 12) {
            Image(systemName: "cursorarrow.motionlines")
                .font(.system(size: 16, weight: .medium))
                .foregroundStyle(HostPalette.success)
                .frame(width: 26, height: 26)

            VStack(alignment: .leading, spacing: 2) {
                Text("Instant pointer")
                    .font(.subheadline.weight(.medium))
                Text("The Mac cursor is hidden from the video. Peering draws it on your iPhone immediately, so it follows your touch without waiting for a frame.")
                    .font(.caption)
                    .foregroundStyle(HostPalette.muted)
                    .fixedSize(horizontal: false, vertical: true)
            }

            Spacer(minLength: 12)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 12)
    }

    /// The size of the picture, which is the setting that trades quality for everything else
    /// at once.
    ///
    /// Worth a switch rather than a constant because of what it is measured against: a phone
    /// draws the whole display a few hundred points wide, so a stream at the display's own
    /// size is already being scaled down by a factor of four before anyone looks at it, and
    /// the pixels given up here are ones the phone was going to throw away.
    private var captureResolutionRow: some View {
        HStack(spacing: 12) {
            Image(systemName: "rectangle.compress.vertical")
                .font(.system(size: 16, weight: .medium))
                .foregroundStyle(HostPalette.ink)
                .frame(width: 26, height: 26)

            VStack(alignment: .leading, spacing: 2) {
                Text("Capture resolution")
                    .font(.subheadline.weight(.medium))
                // Says when it lands, because the switch cannot show it: the setting is read
                // when a stream is built, so a change made with a phone attached looks like
                // one that did nothing until the next capture is started.
                Text("3/4 captures at 75% width and height (~56% of pixels). Half is a quarter of the pixels. Applies when the next stream starts, which is a change of source or the next connection.")
                    .font(.caption)
                    .foregroundStyle(HostPalette.muted)
                    .fixedSize(horizontal: false, vertical: true)
            }

            Spacer(minLength: 12)

            Picker("", selection: Binding(
                get: { model.captureResolution },
                set: { model.setCaptureResolution($0) }
            )) {
                ForEach(CaptureResolution.allCases, id: \.self) { resolution in
                    Text(resolution.title).tag(resolution)
                }
            }
            .labelsHidden()
            .pickerStyle(.segmented)
            .controlSize(.small)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 12)
    }

    /// How many frames a second the stream is asked for.
    ///
    /// The setting for a Mac whose screen moves faster than the phone can be shown it. Only a
    /// panel that refreshes faster than sixty times a second has anything to give here, and
    /// doubling the rate doubles what has to be encoded and sent.
    private var frameRateRow: some View {
        HStack(spacing: 12) {
            Image(systemName: "speedometer")
                .font(.system(size: 16, weight: .medium))
                .foregroundStyle(HostPalette.ink)
                .frame(width: 26, height: 26)

            VStack(alignment: .leading, spacing: 2) {
                Text("Frame rate")
                    .font(.subheadline.weight(.medium))
                Text("30 fps saves bandwidth and battery. 60 fps is the standard. 120 fps only gains anything on a ProMotion display and doubles what must be sent. Applies when the next stream starts.")
                    .font(.caption)
                    .foregroundStyle(HostPalette.muted)
                    .fixedSize(horizontal: false, vertical: true)
            }

            Spacer(minLength: 12)

            Picker("", selection: Binding(
                get: { model.captureFrameRate },
                set: { model.setCaptureFrameRate($0) }
            )) {
                ForEach(CaptureFrameRate.allCases, id: \.self) { rate in
                    Text(rate.title).tag(rate)
                }
            }
            .labelsHidden()
            .pickerStyle(.segmented)
            .controlSize(.small)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 12)
    }

    private var codecRow: some View {
        HStack(spacing: 12) {
            Image(systemName: "film.stack")
                .font(.system(size: 16, weight: .medium))
                .foregroundStyle(HostPalette.ink)
                .frame(width: 26, height: 26)
            VStack(alignment: .leading, spacing: 2) {
                Text("Video codec").font(.subheadline.weight(.medium))
                Text("HEVC saves bandwidth on supported devices. Applies when the next stream starts.")
                    .font(.caption).foregroundStyle(HostPalette.muted)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 12)
            Picker("", selection: Binding(get: { model.captureCodec }, set: { model.setCaptureCodec($0) })) {
                ForEach(VideoCodec.allCases, id: \.self) { codec in Text(codec.title).tag(codec) }
            }
            .labelsHidden().pickerStyle(.segmented).controlSize(.small)
        }
        .padding(.horizontal, 14).padding(.vertical, 12)
    }

    /// The port, as a field rather than the label it used to be.
    ///
    /// A Mac sharing its network with something already on 51515 had nowhere to go, and the
    /// number was a constant compiled into both apps. Bonjour carries whatever is bound here, so
    /// a phone on this network needs no change of its own; only the manual-address path has to be
    /// told, which is what the detail line says.
    private var portRow: some View {
        HStack(spacing: 12) {
            Image(systemName: "number")
                .font(.system(size: 16, weight: .medium))
                .foregroundStyle(model.status.isListening ? HostPalette.ink : HostPalette.muted)
                .frame(width: 26, height: 26)

            VStack(alignment: .leading, spacing: 2) {
                Text("Port")
                    .font(.subheadline.weight(.medium))
                Text("Phones on this network follow it automatically. Changing it restarts the listener and disconnects anyone connected.")
                    .font(.caption)
                    .foregroundStyle(HostPalette.muted)
                    .fixedSize(horizontal: false, vertical: true)
            }

            Spacer(minLength: 12)

            TextField("", text: $portDraft)
                .textFieldStyle(.roundedBorder)
                .frame(width: 78)
                .multilineTextAlignment(.trailing)
                .focused($portFocused)
                .onSubmit { commitPort() }
                .onChange(of: portFocused) { _, focused in
                    if !focused { commitPort() }
                }
                .onAppear { portDraft = String(model.boundPort) }
                .onChange(of: model.boundPort) { _, bound in
                    // Only while nobody is editing it: overwriting the field under a cursor
                    // that is halfway through typing a new number would be the app arguing
                    // with the user about what they meant.
                    if !portFocused { portDraft = String(bound) }
                }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 12)
    }

    /// Applies the draft, or puts the real port back if it is not one.
    private func commitPort() {
        guard let port = UInt16(portDraft.trimmingCharacters(in: .whitespaces)), port > 0 else {
            portDraft = String(model.boundPort)
            return
        }
        model.setPort(port)
        portDraft = String(model.boundPort)
    }

    // MARK: - Devices and activity

    /// What the connected device is looking at.
    ///
    /// First in the window, because it is the question this app exists to answer for whoever is
    /// sitting at the Mac. Everything else — who is attached, whether a permission is granted —
    /// is context for this one fact.
    private var nowShowingSection: some View {
        VStack(alignment: .leading, spacing: 0) {
            // No eyebrow. "LIVE SESSION" sat above this title in tracked capitals and said what
            // the green pill in the sidebar and the green pill in the footer below already said —
            // but the cost was not the repetition, it was the shape: a small tracked caption over
            // a larger line is the skeleton every generated dashboard wears, and it made a window
            // with real information in it look like a mock-up. The title carries itself.
            //
            // The state it was announcing is on the right, where it is worth more: a dot beside
            // the name of the device that is actually connected. A dot that is only there when
            // something is live says more than a label that changes one word.
            HStack(alignment: .center, spacing: 14) {
                Text(capturingTitle)
                    .font(.system(size: 26, weight: .semibold, design: .rounded))
                    .tracking(-0.4)
                    .lineLimit(1)

                Spacer(minLength: 12)

                if let client = connectedClient {
                    VStack(alignment: .trailing, spacing: 3) {
                        HStack(spacing: 6) {
                            Circle()
                                .fill(HostPalette.success)
                                .frame(width: 6, height: 6)
                                .shadow(color: HostPalette.success.opacity(0.6), radius: 4)
                            Text(client.name)
                                .font(.system(size: 12, weight: .semibold))
                                .lineLimit(1)
                        }
                        Text(client.elapsedDescription())
                            .font(.system(size: 11, design: .monospaced))
                            .foregroundStyle(HostPalette.muted)
                    }
                }
            }
            .padding(.horizontal, 18)
            .padding(.top, 16)
            .padding(.bottom, 13)

            VStack(spacing: 0) {
                previewPane

                HStack(spacing: 14) {
                    ZStack {
                        RoundedRectangle(cornerRadius: 10, style: .continuous)
                            .fill(capturingSource == nil ? HostPalette.raised : HostPalette.ink.opacity(0.12))
                        Image(systemName: capturingIcon)
                            .font(.system(size: 18, weight: .medium))
                            .foregroundStyle(capturingSource == nil ? HostPalette.faint : HostPalette.ink)
                    }
                    .frame(width: 40, height: 40)

                    VStack(alignment: .leading, spacing: 3) {
                        Text(capturingDetail)
                            .font(.callout.weight(.medium))
                            .foregroundStyle(HostPalette.muted)
                            .fixedSize(horizontal: false, vertical: true)
                    }

                    Spacer(minLength: 12)

                    if capturingSource != nil {
                        HStack(spacing: 6) {
                            Circle()
                                .fill(HostPalette.success)
                                .frame(width: 6, height: 6)
                                .shadow(color: HostPalette.success.opacity(0.6), radius: 4)
                            Text("Live")
                                .font(.caption.weight(.medium))
                                .foregroundStyle(HostPalette.ink)
                        }
                        .padding(.horizontal, 9)
                        .frame(height: 25)
                        .background(HostPalette.raised, in: Capsule())
                        .overlay { Capsule().strokeBorder(HostPalette.hairline, lineWidth: 1) }
                    }
                }
                .padding(.horizontal, 16)
                .padding(.vertical, 14)
                .background(HostPalette.surface)
            }
            // Concentric with the bezel outside it — the panel's radius less the panel's own
            // padding. Two radii that are close but not equal is the thing that reads as sloppy
            // without anyone being able to say why.
            .clipShape(RoundedRectangle(cornerRadius: HostPalette.panelRadius - 3, style: .continuous))
        }
        .hostPrimaryPanel()
        .scaleEffect(heroHovered ? 1.002 : 1)
        .onHover { hovering in
            withAnimation(HostMotion.hover) { heroHovered = hovering }
        }
    }

    /// The shape the frame should be.
    ///
    /// Whatever is actually being sent, and the display when nothing is — which is also what a
    /// connection captures until the client asks for something else, so the frame does not change
    /// shape the moment a stream starts.
    private var previewAspect: CGFloat {
        if let preview, preview.height > 0 {
            return CGFloat(preview.width) / CGFloat(preview.height)
        }
        if let screen = NSScreen.screens.first, screen.frame.height > 0 {
            return screen.frame.width / screen.frame.height
        }
        return 16.0 / 10.0
    }

    /// How tall the picture's frame is: as tall as the pane is wide, in the picture's own shape.
    ///
    /// A band of fixed height was the first thing this was, and it was wrong for the reason any
    /// fixed frame around a variable picture is wrong — a Mac display is wider than it is tall by
    /// half again, so a wide short band left a stripe of black down each side of the picture and a
    /// wide window made the stripe wider instead of the picture larger. The frame takes the
    /// picture's shape, and the picture fills it.
    ///
    /// Capped at 4:3, which is the one place the shape does not win. A single tall window is a
    /// legitimate thing to share, and its shape would otherwise ask for a frame taller than the
    /// window it is in — so past that the picture letterboxes instead, and the layout is not held
    /// hostage by the narrowest thing someone might have picked.
    private var previewHeight: CGFloat {
        let panel = max((paneWidth > 0 ? paneWidth : 1000) - Self.paneInset * 2, 320)
        return min(max(panel / previewAspect, 220), panel * 0.75)
    }

    /// The picture itself, in a frame cut to its own shape.
    ///
    /// The letterbox is black because that is what the phone is being sent, so the two show the
    /// same frame — and it should be visible only where the picture genuinely does not fill the
    /// shape, which is the capped case above rather than every case.
    private var previewPane: some View {
        ZStack {
            Color.black

            if let preview {
                Image(decorative: preview, scale: 1)
                    .resizable()
                    .aspectRatio(contentMode: .fit)
            } else {
                VStack(spacing: 7) {
                    Image(systemName: capturingSource == nil ? "rectangle.slash" : "ellipsis")
                        .font(.system(size: 21, weight: .light))
                    Text(capturingSource == nil ? "Not streaming" : "Starting…")
                        .font(.caption)
                }
                .foregroundStyle(HostPalette.faint)
            }
        }
        .frame(height: previewHeight)
        .frame(maxWidth: .infinity)
        .animation(HostMotion.state, value: preview == nil)
        .accessibilityHidden(true)
    }

    private var capturingSource: CaptureSource? { model.capturingSource }

    private var capturingIcon: String {
        switch capturingSource {
        case .display: return "display"
        case .application: return "macwindow.on.rectangle"
        case .window: return "macwindow"
        // Not `display.slash`: that symbol does not exist in SF Symbols, and a name that resolves
        // to nothing draws nothing — the chip came out as an empty rounded square, which reads as
        // a rendering fault rather than as a state. `rectangle.slash` is the one that is there.
        case nil: return "rectangle.slash"
        }
    }

    /// The catalogue's name for the source where there is one, and a description of the state
    /// where there is not — a bare display ID would be a worse answer than an honest sentence.
    private var capturingTitle: String {
        if let title = model.capturingSourceTitle { return title }
        return model.connectedClients.isEmpty ? "Nothing yet" : "Choosing a screen…"
    }

    private var capturingDetail: String {
        guard let capturingSource else {
            return model.connectedClients.isEmpty
                ? "No device is connected."
                : "A device is connected but has not chosen what to show."
        }
        switch capturingSource {
        case .display: return "The whole screen, streaming live."
        case .application: return "One application, streaming live."
        case .window: return "One window, streaming live."
        }
    }

    // MARK: - Devices

    /// On a wide window the compact device list sits beside the longer activity feed, making
    /// the overview an intentionally uneven dashboard. At the minimum window width it falls
    /// back to the familiar vertical reading order.
    private var overviewLowerDeck: some View {
        ViewThatFits(in: .horizontal) {
            HStack(alignment: .top, spacing: 18) {
                devicesSection.frame(width: 260, alignment: .topLeading)
                activitySection.frame(minWidth: 360, alignment: .topLeading)
            }
            VStack(alignment: .leading, spacing: 24) {
                devicesSection
                activitySection
            }
        }
    }

    /// Who is trusted, and which of them is here.
    ///
    /// The absent rows matter as much as the present ones. "Is that phone still allowed in" is
    /// a question asked when the phone is *not* on the desk, and a pin — which is all the host
    /// stores for a trusted device — carries no name, so an unattached device is named from the
    /// last time it connected.
    private var devicesSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(alignment: .firstTextBaseline) {
                sectionHeading("Devices", detail: "Phones trusted to reach this Mac.")
                Spacer()
                if !model.pairedClientIDs.isEmpty {
                    Button("Forget all", role: .destructive) { model.unpairAll() }
                        .controlSize(.small)
                }
            }

            if model.pairedClientIDs.isEmpty {
                HStack(spacing: 12) {
                    Image(systemName: "iphone.slash")
                        .font(.title3)
                        .foregroundStyle(HostPalette.faint)
                    Text("No iPhones paired yet")
                        .font(.callout)
                        .foregroundStyle(HostPalette.muted)
                }
                .padding(.vertical, 8)
            } else {
                let connected = model.connectedClients
                let offline = model.pairedClientIDs.filter { !model.isConnected($0) }

                VStack(spacing: 0) {
                    ForEach(Array(connected.enumerated()), id: \.element.id) { index, client in
                        if index > 0 { Divider().padding(.leading, 44) }
                        deviceRow(
                            name: client.name,
                            id: client.id,
                            detail: "Connected · \(client.elapsedDescription())",
                            connected: true
                        )
                    }
                    ForEach(Array(offline.enumerated()), id: \.element) { index, id in
                        if index > 0 || !connected.isEmpty { Divider().padding(.leading, 44) }
                        deviceRow(
                            name: model.displayName(for: id),
                            id: id,
                            detail: "Trusted · not connected",
                            connected: false
                        )
                    }
                }
                .hostPanel()
            }
        }
    }

    private func deviceRow(name: String, id: String, detail: String, connected: Bool) -> some View {
        HStack(spacing: 14) {
            ZStack {
                RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .fill(connected ? HostPalette.success.opacity(0.13) : HostPalette.raised)
                Image(systemName: connected ? "iphone.radiowaves.left.and.right" : "iphone")
                    .font(.system(size: 16, weight: .medium))
                    .foregroundStyle(connected ? HostPalette.success : HostPalette.faint)
            }
            .frame(width: 36, height: 36)
            .overlay {
                RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .strokeBorder(connected ? HostPalette.success.opacity(0.18) : HostPalette.hairline)
            }
            VStack(alignment: .leading, spacing: 2) {
                Text(name)
                    .font(.subheadline.weight(.medium))
                    .lineLimit(1)
                Text(detail)
                    .font(.caption)
                    .foregroundStyle(connected ? HostPalette.success : HostPalette.muted)
                    .monospacedDigit()
            }
            Spacer(minLength: 12)
            if connected {
                Text("LIVE")
                    .font(.system(size: 9, weight: .bold))
                    .tracking(0.7)
                    .foregroundStyle(HostPalette.success)
            }
            Button(role: .destructive) {
                forgetDevice = (id, name)
            } label: {
                Image(systemName: "xmark")
                    .font(.system(size: 10, weight: .semibold))
                    .frame(width: 20, height: 20)
            }
            .buttonStyle(.plain)
            .foregroundStyle(hoveredDeviceID == id ? HostPalette.danger : HostPalette.faint)
            .help("Forget (name)")
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 11)
        .background(
            hoveredDeviceID == id ? HostPalette.raised : .clear,
            in: RoundedRectangle(cornerRadius: 11, style: .continuous)
        )
        .scaleEffect(hoveredDeviceID == id ? 1.004 : 1)
        .contentShape(Rectangle())
        .onHover { hovering in
            withAnimation(HostMotion.hover) { hoveredDeviceID = hovering ? id : nil }
        }
        // The ID is what a pairing question turns on, so it stays reachable — as a tooltip
        // rather than as the thing printed on the row, where it was never what anyone
        // recognised.
        .help("Device ID \(id)")
    }

    /// A tail of what the host has done.
    ///
    /// Full width and below rather than a column of its own. These are sentences, and a narrow
    /// column wrapped every one of them into three lines to say what fitted on one.
    ///
    /// `Copy all` rather than leaving it to selection: the lines are separate text blocks, so
    /// dragging across them gets one line at a time — which is no way to hand anyone a run of
    /// events. The selection stays enabled for the single line someone wants to quote.
    private var activitySection: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(alignment: .firstTextBaseline) {
                sectionHeading("Activity", detail: "Recent host events, newest last.")
                Spacer()
                if !model.log.isEmpty {
                    Button("Copy all") {
                        let board = NSPasteboard.general
                        board.clearContents()
                        board.setString(model.logText, forType: .string)
                    }
                    .controlSize(.small)
                    .help("Copies every line, with its timestamp")
                }
            }

            if model.log.isEmpty {
                HStack(spacing: 11) {
                    Image(systemName: "waveform.path")
                        .font(.system(size: 17, weight: .medium))
                        .foregroundStyle(HostPalette.faint)
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Waiting for activity")
                            .font(.subheadline.weight(.medium))
                        Text("Connections, stream changes and problems will appear here.")
                            .font(.caption)
                            .foregroundStyle(HostPalette.faint)
                    }
                }
                .frame(maxWidth: .infinity, minHeight: 82, alignment: .leading)
                .padding(16)
                .hostPanel()
            } else {
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 0) {
                        ForEach(Array(model.log.enumerated()), id: \.element.id) { index, entry in
                            activityRow(entry)
                            if index < model.log.count - 1 {
                                Divider().padding(.leading, 42)
                            }
                        }
                    }
                }
                .frame(minHeight: 150, maxHeight: 320)
                .hostPanel()
            }
        }
    }

    private func activityRow(_ entry: HostLogEntry) -> some View {
        HStack(alignment: .top, spacing: 11) {
            Image(systemName: entry.levelSymbol)
                .font(.system(size: entry.level == .info ? 7 : 13, weight: .semibold))
                .foregroundStyle(colour(for: entry.level))
                .frame(width: 20, height: 20)

            VStack(alignment: .leading, spacing: 4) {
                Text(entry.message)
                    .font(.system(size: 12.5, weight: entry.level == .info ? .regular : .medium))
                    .foregroundStyle(entry.level == .info ? HostPalette.ink : colour(for: entry.level))
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)

                HStack(spacing: 6) {
                    Text(entry.time)
                        .monospacedDigit()
                    Text(entry.levelName)
                }
                .font(.system(size: 10.5, weight: .medium))
                .foregroundStyle(HostPalette.faint)
            }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
        .background(entry.level == .failure ? HostPalette.danger.opacity(0.055) : .clear)
    }

    /// Three tones and no more: routine, worth noticing, did not work.
    ///
    /// The rest of the window keeps to brightness, but a failure is the one thing here a reader
    /// has to find by skimming, and losing it in grey is how a log stops being read at all.
    private func colour(for level: HostLogEntry.Level) -> Color {
        switch level {
        case .info: return HostPalette.faint
        case .warning: return HostPalette.caution
        case .failure: return HostPalette.danger
        }
    }

    // MARK: - Sessions

    /// What has already happened, and what it cost.
    ///
    /// The live figures vanish the moment the phone disconnects — which is precisely when
    /// someone wants to look at them — so each finished session is written down as it ends.
    private var sessionsSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            sectionHeading("Sessions", detail: "Finished connections, newest first.")

            if model.sessions.isEmpty {
                Text("No sessions yet.")
                    .font(.callout)
                    .foregroundStyle(HostPalette.faint)
                    .padding(.vertical, 8)
            } else {
                VStack(spacing: 0) {
                    ForEach(Array(model.sessions.enumerated()), id: \.element.id) { index, session in
                        if index > 0 { Divider().padding(.leading, 14) }
                        sessionRow(session)
                    }
                }
                .hostPanel()

                Text("Bytes are what the host sent: the video stream. Control traffic is a rounding error beside it.")
                    .font(.caption)
                    .foregroundStyle(HostPalette.faint)
            }
        }
    }

    private func sessionRow(_ session: HostSessionRecord) -> some View {
        HStack(spacing: 12) {
            Image(systemName: "iphone")
                .font(.system(size: 15, weight: .medium))
                .foregroundStyle(HostPalette.faint)
                .frame(width: 22, height: 22)

            VStack(alignment: .leading, spacing: 2) {
                Text(session.deviceName)
                    .font(.subheadline.weight(.medium))
                    .lineLimit(1)
                Text(session.startedDescription)
                    .font(.caption)
                    .foregroundStyle(HostPalette.muted)
            }

            Spacer(minLength: 12)

            Text(session.durationDescription)
                .font(.callout)
                .monospacedDigit()
            Text(session.bytesDescription)
                .font(.caption)
                .monospacedDigit()
                .foregroundStyle(HostPalette.muted)
                .frame(width: 74, alignment: .trailing)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
    }

    // MARK: - Privacy

    /// What pairing actually grants, said plainly.
    ///
    /// Worth the space: "trusted device" is a phrase that sounds broader than it is, and the
    /// honest answer — it can see the screen you chose and send input — is both narrower and
    /// easier to reason about than a phrase like "full access".
    private var privacyNote: some View {
        VStack(alignment: .leading, spacing: 12) {
            sectionHeading("What a trusted phone can do", detail: "The whole of it.")

            VStack(alignment: .leading, spacing: 10) {
                privacyRow(
                    "See the screen you share",
                    "The captured display, window or application, and the list of things this Mac could capture, which includes window titles, application names and their icons."
                )
                Divider()
                privacyRow(
                    "Send clicks and keystrokes",
                    "Injected through the same mechanism an assistive keyboard uses, which is why the Accessibility permission is required."
                )
                Divider()
                privacyRow(
                    "Clipboard, when you ask",
                    "Clipboard text moves only when you use Pull or Push on the iPhone. Files, the microphone and the camera are not sent."
                )
            }
            .padding(14)
            .hostPanel()
        }
    }

    private func privacyRow(_ title: String, _ detail: String) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(title).font(.subheadline.weight(.medium))
            Text(detail)
                .font(.caption)
                .foregroundStyle(HostPalette.muted)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    // MARK: - About

    private var aboutSection: some View {
        VStack(alignment: .leading, spacing: 22) {
            HStack(spacing: 16) {
                Image(nsImage: NSApplication.shared.applicationIconImage)
                    .resizable()
                    .frame(width: 72, height: 72)
                    .accessibilityHidden(true)

                VStack(alignment: .leading, spacing: 3) {
                    Text("Peering")
                        .font(.system(size: 24, weight: .semibold, design: .rounded))
                    Text("Your Mac, right here.")
                        .font(.callout)
                        .foregroundStyle(HostPalette.muted)
                }
            }

            VStack(alignment: .leading, spacing: 8) {
                LabeledContent("Protocol", value: "v\(ProtocolInfo.version)")
                LabeledContent("Port", value: "\(model.boundPort)")
                LabeledContent("Device ID", value: model.deviceID)
            }
            .font(.callout)
            .padding(14)
            .frame(maxWidth: .infinity, alignment: .leading)
            .hostPanel()
            .textSelection(.enabled)

            VStack(alignment: .leading, spacing: 10) {
                Text("This is a personal project, and it will not ask you for an account or a subscription.")
                    .font(.caption)
                    .foregroundStyle(HostPalette.muted)
                    .fixedSize(horizontal: false, vertical: true)

                Link(destination: Self.supportURL) {
                    Label("Buy me a coffee", systemImage: "cup.and.saucer")
                }
                .controlSize(.large)
            }
        }
    }

    /// Where the About pane points. **Set this to your own page** — leaving it at the site root
    /// means the button takes people somewhere that is not about you.
    private static let supportURL = URL(string: "https://buymeacoffee.com/")!

    private func sectionHeading(_ title: String, detail: String) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(title)
                .font(.system(size: 17, weight: .semibold, design: .rounded))
                .tracking(-0.2)
            Text(detail).font(.caption).foregroundStyle(HostPalette.muted)
        }
    }

    // MARK: - Helpers

    /// Connected outranks listening: "is anyone there" is the question this window is answering,
    /// and "Ready for iPhone" is true whether or not a client is attached — which is why it was
    /// the wrong thing to say while one was.
    private var statusColor: Color {
        if !model.connectedClients.isEmpty { return HostPalette.success }
        switch model.status {
        case .listening: return HostPalette.accent
        case .starting: return HostPalette.faint
        case .idle: return HostPalette.faint
        case .failed: return HostPalette.danger
        }
    }

    private var statusText: String {
        if let client = model.connectedClients.first {
            let others = model.connectedClients.count - 1
            return others > 0 ? "Connected: \(client.name) +\(others)" : "Connected: \(client.name)"
        }
        switch model.status {
        case .idle: return "Not hosting"
        case .starting: return "Starting…"
        case .listening: return "Waiting for a device"
        case .failed(let message): return "Error: \(message)"
        }
    }

    /// The longest-attached device, or nil when none is.
    ///
    /// With more than one client attached the oldest is the session — it is the one that has
    /// been waiting to be noticed for longest.
    private var connectedClient: ConnectedClient? {
        model.connectedClients.min { $0.since < $1.since }
    }

    /// Grouped as `123 456`. Six unbroken digits are harder to compare by eye.
    private func formatted(_ code: String) -> String {
        guard code.count == 6 else { return code }
        let middle = code.index(code.startIndex, offsetBy: 3)
        return "\(code[code.startIndex..<middle]) \(code[middle...])"
    }

    private func qrCode(for code: String) -> NSImage? {
        let filter = CIFilter.qrCodeGenerator()
        filter.message = Data("peering://pair?code=\(code)".utf8)
        filter.correctionLevel = "M"
        guard let output = filter.outputImage?.transformed(by: .init(scaleX: 9, y: 9)) else {
            return nil
        }
        let representation = NSCIImageRep(ciImage: output)
        let image = NSImage(size: representation.size)
        image.addRepresentation(representation)
        return image
    }
}

/// The two sizes and the two rates as words.
///
/// Deliberately without the pixel dimensions: the size a stream is built at follows the
/// source, and the source is the phone's to choose — a label carrying numbers would be
/// wrong for every source but the one that happened to be selected when the window was
/// drawn, and the row is on screen while the client switches between them.
private extension CaptureResolution {
    var title: String {
        switch self {
        case .full: return "Full"
        case .threeQuarters: return "3/4"
        case .half: return "Half"
        }
    }
}

private extension CaptureFrameRate {
    var title: String {
        switch self {
        case .thirty: return "30 fps"
        case .sixty: return "60 fps"
        case .oneTwenty: return "120 fps"
        }
    }
}

private extension View {
    /// The pairing card, and the one place in the window that is allowed to raise its voice.
    ///
    /// A pairing request is the only thing here that needs an answer from the person at the Mac,
    /// so it lifts off the stage further than a panel does and takes the accent into its edge —
    /// the whole card, rather than a coloured bar down one side of it.
    func priorityPanel() -> some View {
        padding(20)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(HostPalette.raised, in: RoundedRectangle(cornerRadius: HostPalette.panelRadius, style: .continuous))
            .overlay {
                RoundedRectangle(cornerRadius: HostPalette.panelRadius, style: .continuous)
                    .strokeBorder(HostPalette.accent.opacity(0.35), lineWidth: 1)
            }
            .shadow(color: .black.opacity(0.4), radius: 20, y: 9)
    }
}

#Preview {
    HostStatusView()
        .environment(HostModel())
}
