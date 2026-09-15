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

    var body: some View {
        NavigationSplitView {
            sidebar
                .navigationSplitViewColumnWidth(min: 190, ideal: 210, max: 250)
        } detail: {
            ZStack {
                Color(nsColor: .windowBackgroundColor).ignoresSafeArea()

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
                    .padding(.horizontal, 26)
                    .padding(.top, 22)
                    .padding(.bottom, 28)
                    // The pane is only as wide as its widest row, and a scroll view centres
                    // what it is given. Overview looked right by accident — the preview pane
                    // asks for the full width — while a pane holding one short line of text
                    // floated in the middle of the window.
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
        .tint(HostPalette.ink)
        .frame(minWidth: 760, minHeight: 560)
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
    }

    // MARK: - Status

    // MARK: - Sidebar

    private var sidebar: some View {
        VStack(spacing: 0) {
            sidebarHeader
            Divider().opacity(0.6)
            List(HostSection.allCases, selection: $section) { item in
                Label(item.title, systemImage: item.symbol)
                    .tag(item)
            }
            .listStyle(.sidebar)
        }
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
                    .accessibilityHidden(true)

                VStack(alignment: .leading, spacing: 1) {
                    Text("Peering")
                        .font(.system(size: 17, weight: .semibold, design: .rounded))
                    Text(model.deviceName)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }

                Spacer(minLength: 0)
            }

            // The sentence can outrun the column — "Connected — Damian's iPhone" is most of it
            // — so it truncates and carries the whole thing as a tooltip.
            HStack(spacing: 6) {
                Circle().fill(statusColor).frame(width: 7, height: 7)
                Text(statusText)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
            .help(statusText)

            // The frame goes on the label, not the button. A bordered button sizes itself to
            // its label, so widening the button only pads the space around it — the control
            // stays the size of the word and sits in the middle of the column.
            //
            // Big, and it is the only coloured control in the app. Both are deliberate. This is
            // the one thing the whole window exists to offer, and it used to be a small grey
            // word in the middle of a column — the least prominent thing on a screen whose only
            // question is whether the Mac is being shared. The palette is monochrome everywhere
            // else and stays that way; this is the exception that earns it.
            //
            // The accent rather than a colour of this app's own, so it is whatever the user has
            // already told macOS means "this is the thing to press". Quiet when it stops: the
            // two states are not equals, and one of them is how you put it down.
            Button {
                model.status.isListening ? model.stop() : model.start()
            } label: {
                Text(model.status.isListening ? "Stop" : "Start")
                    .font(.headline)
                    .frame(maxWidth: .infinity)
                    .frame(height: 34)
            }
            .buttonStyle(.borderedProminent)
            .tint(model.status.isListening ? Color.secondary : Color.accentColor)
            .animation(nil, value: model.status.isListening)

            Text("Port \(model.boundPort) · protocol v\(ProtocolInfo.version)")
                .font(.caption2.monospacedDigit())
                .foregroundStyle(.tertiary)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 14)
    }

    // MARK: - Detail

    @ViewBuilder
    private var pane: some View {
        switch section {
        case .overview:
            VStack(alignment: .leading, spacing: 24) {
                connectSection
                nowShowingSection
                devicesSection
                activitySection
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
    /// this screen read as a single empty panel. This is the question that comes first, and the
    /// only one with anything to say when the Mac is waiting.
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
                .background(HostPalette.surface, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
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
                    .foregroundStyle(.secondary)
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
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)

                    Text(formatted(pairing.code))
                        .font(.system(size: 42, weight: .semibold, design: .monospaced))
                        .tracking(2)
                        .textSelection(.enabled)

                    Label("Only pair a device you recognize.", systemImage: "lock.fill")
                        .font(.caption)
                        .foregroundStyle(.secondary)
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
                        .foregroundStyle(.secondary)
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
            .background(HostPalette.surface, in: RoundedRectangle(cornerRadius: 12, style: .continuous))

            HStack(spacing: 8) {
                Button("Check again") { model.refreshPermissions() }
                    .controlSize(.small)
                Text("Restart Peering after changing a permission.")
                    .font(.caption)
                    .foregroundStyle(.tertiary)
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
                Text(detail).font(.caption).foregroundStyle(.secondary)
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
                        Text("Prevent lid-close sleep")
                            .font(.subheadline.weight(.medium))
                        Text("Keeps the Mac awake when the lid is closed. Lifted automatically when Peering quits.")
                            .font(.caption)
                            .foregroundStyle(.secondary)
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

                pointerRow

                Divider().padding(.leading, 52)

                pointerSizeRow

                Divider().padding(.leading, 52)

                captureResolutionRow

                Divider().padding(.leading, 52)

                frameRateRow

                Divider().padding(.leading, 52)

                portRow
            }
            .background(HostPalette.surface, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
        }
    }

    /// The enlarged pointer, which is a setting because of where it goes wrong.
    ///
    /// Everything else on this pane is about the Mac it runs on. This changes what the phone
    /// sees and nothing else, so the only place a bad choice shows up is on the phone, and
    /// the only place to undo it is here.
    private var pointerRow: some View {
        HStack(spacing: 12) {
            Image(systemName: "cursorarrow")
                .font(.system(size: 16, weight: .medium))
                .foregroundStyle(model.enlargePointer ? HostPalette.ink : HostPalette.muted)
                .frame(width: 26, height: 26)

            VStack(alignment: .leading, spacing: 2) {
                Text("Larger pointer")
                    .font(.subheadline.weight(.medium))
                // Says what *off* means, because it is not "draw nothing" and it is not
                // "no pointer": the system's pointer goes back into the capture and the small
                // one the phone had before returns. It also takes effect on the next
                // connection rather than the next frame, which is worth saying here rather
                // than leaving to be discovered.
                Text("Draws a bigger pointer into the video so it is easier to see on a phone. The pointer on this Mac is not changed. With this off the Mac's own pointer is sent instead, which is smaller. Changing it applies to the next connection.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            Spacer(minLength: 12)

            Toggle("", isOn: Binding(
                get: { model.enlargePointer },
                set: { model.setEnlargePointer($0) }
            ))
            .labelsHidden()
            .toggleStyle(.switch)
            .controlSize(.small)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 12)
    }

    /// How much larger, which is the half of the question the switch cannot ask.
    ///
    /// Dimmed rather than hidden while the pointer is off: a row that comes and goes moves the
    /// ones under it, and the value is still the one the next frame will use.
    private var pointerSizeRow: some View {
        HStack(spacing: 12) {
            Image(systemName: "arrow.up.left.and.arrow.down.right")
                .font(.system(size: 16, weight: .medium))
                .foregroundStyle(model.enlargePointer ? HostPalette.ink : HostPalette.muted)
                .frame(width: 26, height: 26)

            VStack(alignment: .leading, spacing: 2) {
                Text("Pointer size")
                    .font(.subheadline.weight(.medium))
                Text("How much larger than the pointer this Mac is showing.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            Spacer(minLength: 12)

            Picker("", selection: Binding(
                get: { model.pointerSize },
                set: { model.setPointerSize($0) }
            )) {
                ForEach(CursorOverlay.Size.allCases, id: \.self) { size in
                    Text(size.title).tag(size)
                }
            }
            .labelsHidden()
            .pickerStyle(.segmented)
            .controlSize(.small)
            .disabled(!model.enlargePointer)
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
                Text("Half captures at half the width and height, so a quarter of the pixels to send. Applies when the next stream starts, which is a change of source or the next connection.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
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
                Text("How many frames a second to send. A screen that cannot run this fast sends what it can. Applies when the next stream starts, which is a change of source or the next connection.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
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
                    .foregroundStyle(.secondary)
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
        VStack(alignment: .leading, spacing: 12) {
            sectionHeading("Now showing", detail: "What the connected device can see.")

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
                        Text(capturingTitle)
                            .font(.title3.weight(.semibold))
                            .lineLimit(1)
                        Text(capturingDetail)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }

                    Spacer(minLength: 12)

                    if capturingSource != nil {
                        HStack(spacing: 5) {
                            Circle().fill(HostPalette.ink).frame(width: 6, height: 6)
                            Text("Live").font(.caption.weight(.medium))
                        }
                        .foregroundStyle(HostPalette.ink)
                    }
                }
                .padding(.horizontal, 16)
                .padding(.vertical, 14)
                .background(HostPalette.surface)
            }
            .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
        }
    }

    /// The picture itself, letterboxed inside a fixed band.
    ///
    /// A fixed height rather than one the aspect ratio decides: a source can be any shape — a
    /// 16:10 display, a tall window, a phone-shaped one — and a card that resized itself as the
    /// client switched would shuffle everything below it on every tap. The letterbox is black
    /// because that is what the phone is being sent, so the two show the same frame.
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
                .foregroundStyle(.white.opacity(0.32))
            }
        }
        .frame(height: 210)
        .frame(maxWidth: .infinity)
        .animation(.easeInOut(duration: 0.2), value: preview == nil)
        .accessibilityHidden(true)
    }

    private var capturingSource: CaptureSource? { model.capturingSource }

    private var capturingIcon: String {
        switch capturingSource {
        case .display: return "display"
        case .application: return "macwindow.on.rectangle"
        case .window: return "macwindow"
        case nil: return "display.slash"
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
                        .foregroundStyle(.tertiary)
                    Text("No iPhones paired yet")
                        .font(.callout)
                        .foregroundStyle(.secondary)
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
                .background(HostPalette.surface, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
            }
        }
    }

    private func deviceRow(name: String, id: String, detail: String, connected: Bool) -> some View {
        HStack(spacing: 14) {
            Image(systemName: "iphone")
                .font(.system(size: 17, weight: .medium))
                .foregroundStyle(connected ? HostPalette.ink : HostPalette.faint)
                .frame(width: 30, height: 30)
            VStack(alignment: .leading, spacing: 2) {
                Text(name)
                    .font(.subheadline.weight(.medium))
                    .lineLimit(1)
                Text(detail)
                    .font(.caption)
                    .foregroundStyle(connected ? HostPalette.ink : HostPalette.muted)
                    .monospacedDigit()
            }
            Spacer(minLength: 12)
            Circle()
                .fill(connected ? HostPalette.ink : HostPalette.faint.opacity(0.4))
                .frame(width: 7, height: 7)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 11)
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
                Text("Waiting for a connection…")
                    .font(.callout)
                    .foregroundStyle(.tertiary)
                    .frame(maxWidth: .infinity, minHeight: 90, alignment: .topLeading)
                    .padding(14)
                    .background(HostPalette.surface, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
            } else {
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 6) {
                        ForEach(model.log) { entry in
                            HStack(alignment: .firstTextBaseline, spacing: 10) {
                                Text(entry.time)
                                    .font(.system(size: 11, design: .monospaced))
                                    .foregroundStyle(.tertiary)
                                Text(entry.message)
                                    .font(.system(size: 11.5))
                                    .foregroundStyle(colour(for: entry.level))
                                    .textSelection(.enabled)
                                    .frame(maxWidth: .infinity, alignment: .leading)
                            }
                        }
                    }
                    .padding(14)
                }
                .frame(minHeight: 150, maxHeight: 320)
                .background(HostPalette.surface, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
            }
        }
    }

    /// Three tones and no more: routine, worth noticing, did not work.
    ///
    /// The rest of the window keeps to brightness, but a failure is the one thing here a reader
    /// has to find by skimming, and losing it in grey is how a log stops being read at all.
    private func colour(for level: HostLogEntry.Level) -> Color {
        switch level {
        case .info: return HostPalette.muted
        case .warning: return HostPalette.ink
        case .failure: return .red
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
                    .foregroundStyle(.tertiary)
                    .padding(.vertical, 8)
            } else {
                VStack(spacing: 0) {
                    ForEach(Array(model.sessions.enumerated()), id: \.element.id) { index, session in
                        if index > 0 { Divider().padding(.leading, 14) }
                        sessionRow(session)
                    }
                }
                .background(HostPalette.surface, in: RoundedRectangle(cornerRadius: 12, style: .continuous))

                Text("Bytes are what the host sent: the video stream. Control traffic is a rounding error beside it.")
                    .font(.caption)
                    .foregroundStyle(.tertiary)
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
                    .foregroundStyle(.secondary)
            }

            Spacer(minLength: 12)

            Text(session.durationDescription)
                .font(.callout)
                .monospacedDigit()
            Text(session.bytesDescription)
                .font(.caption)
                .monospacedDigit()
                .foregroundStyle(.secondary)
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
                    "Nothing else",
                    "Files, the clipboard, the microphone and the camera are not part of this protocol and are never sent."
                )
            }
            .padding(14)
            .background(HostPalette.surface, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
        }
    }

    private func privacyRow(_ title: String, _ detail: String) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(title).font(.subheadline.weight(.medium))
            Text(detail)
                .font(.caption)
                .foregroundStyle(.secondary)
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
                        .foregroundStyle(.secondary)
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
            .background(HostPalette.surface, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
            .textSelection(.enabled)

            VStack(alignment: .leading, spacing: 10) {
                Text("This is a personal project, and it will not ask you for an account or a subscription.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
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
        VStack(alignment: .leading, spacing: 3) {
            Text(title).font(.headline)
            Text(detail).font(.caption).foregroundStyle(.secondary)
        }
    }

    // MARK: - Helpers

    /// Connected outranks listening: "is anyone there" is the question this window is answering,
    /// and "Ready for iPhone" is true whether or not a client is attached — which is why it was
    /// the wrong thing to say while one was.
    private var statusColor: Color {
        if !model.connectedClients.isEmpty { return HostPalette.ink }
        switch model.status {
        case .listening: return HostPalette.muted
        case .starting: return HostPalette.faint
        case .idle: return HostPalette.faint
        case .failed: return HostPalette.ink
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

/// The sizes as words, which is the only form of them a user has an opinion about. The overlay
/// itself deals in fractions of the frame's height, and those are not a question to put to
/// anybody.
private extension CursorOverlay.Size {
    var title: String {
        switch self {
        case .small: return "Small"
        case .medium: return "Medium"
        case .large: return "Large"
        }
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
        case .half: return "Half"
        }
    }
}

private extension CaptureFrameRate {
    var title: String {
        switch self {
        case .sixty: return "60 fps"
        case .oneTwenty: return "120 fps"
        }
    }
}

private extension View {
    func priorityPanel() -> some View {
        padding(20)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(HostPalette.raised, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
            .overlay {
                RoundedRectangle(cornerRadius: 16, style: .continuous)
                    .strokeBorder(Color.accentColor.opacity(0.22))
            }
    }
}

#Preview {
    HostStatusView()
        .environment(HostModel())
}
