import RemoteCore
import SwiftUI
import VideoToolbox

/// Everything the session sheet used to hold, as a floating panel.
///
/// A `List` of `Section`s does not survive being put on top of live video inside a sheet of glass —
/// it brings its own background, its own separators and its own inset behaviour, all of which were
/// chosen for a screen filling the display. This is the same content grouped by the panel's own
/// rules, so the settings look like the rest of the in-session chrome rather than like a piece of
/// iOS that landed on top of it.
struct SettingsPanel: View {
    @Environment(SessionModel.self) private var model

    @Binding var chromeFrames: [ChromeRegion: CGRect]

    /// Opens the source picker in this same panel rather than stacking a second one beside it.
    var onShowSources: () -> Void

    @State private var confirmLock = false

    /// Read here as well as in the screen that obeys it. Same key, one name for it in
    /// ``PreferenceKey`` — two spellings would be a switch that does nothing for one of them.
    @AppStorage(PreferenceKey.hidesPanelAfterSelect) private var hidesPanelAfterSelect = true
    /// Read here as well as in ``SessionPiP``, under the same key — see ``PreferenceKey``.
    @AppStorage(PreferenceKey.pipAutoStart) private var pipAutoStart = true
    /// Read here to say what it does in words, and in ``SessionModel`` to obey it. The default
    /// matches the model's: on, which is how the app behaved before the switch existed.
    @AppStorage(PreferenceKey.allowRelay) private var allowsRelay = true

    var body: some View {
        ScrollView(.vertical, showsIndicators: false) {
            VStack(alignment: .leading, spacing: 16) {
                session
                activity
                stream
                picture
                panels
                privacy
                keyboard
                macros
                pairedMacs
                thisDevice
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(10)
        .glassEffect(.regular, in: RoundedRectangle(cornerRadius: 22, style: .continuous))
        .padding(.horizontal, 10)
        .reportChromeFrame(.panel, into: $chromeFrames)
        .transition(.move(edge: .bottom).combined(with: .opacity))
        .confirmationDialog(
            "Lock this Mac?",
            isPresented: $confirmLock,
            titleVisibility: .visible
        ) {
            Button("Lock Mac", role: .destructive) { model.lockMac() }
        } message: {
            Text("The Mac will lock immediately. macOS does not allow a remote app to bypass its secure login screen, so someone must unlock it locally. Peering will reconnect automatically after wake or unlock.")
        }
    }

    private var session: some View {
        VStack(alignment: .leading, spacing: 6) {
            SectionLabel("Session")
            info("Mac", model.hostName ?? "None")
            info("State", stateDescription)
            info("Path", model.connectionPath?.rawValue ?? "None")
            info("Video", model.videoStatus)
            if let latency = model.latencyMilliseconds {
                info("Latency", "\(Int(latency.rounded())) ms")
            }
            info("This device", model.thisDeviceDescription)
            Button(role: .destructive) { confirmLock = true } label: {
                Label("Lock Mac · unlock locally", systemImage: "lock.fill")
                    .font(.subheadline.weight(.semibold))
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 9)
                    .rowSurface()
                    .contentShape(Rectangle())
            }
            .buttonStyle(RailButtonStyle(scale: 0.98))
        }
    }

    private var hevcSupported: Bool {
        VTIsHardwareDecodeSupported(kCMVideoCodecType_HEVC)
    }

    private var activity: some View {
        VStack(alignment: .leading, spacing: 6) {
            SectionLabel("Recent activity")
            if model.notes.isEmpty {
                HStack(spacing: 9) {
                    Image(systemName: "waveform.path")
                        .foregroundStyle(.secondary)
                    Text("Connection activity will appear here.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                .padding(.horizontal, 10)
                .padding(.vertical, 9)
                .rowSurface()
            } else {
                ForEach(Array(model.notes.suffix(6).reversed().enumerated()), id: \.offset) { _, note in
                    HStack(alignment: .top, spacing: 9) {
                        Image(systemName: note.localizedCaseInsensitiveContains("fail")
                              || note.localizedCaseInsensitiveContains("ended")
                              ? "exclamationmark.triangle.fill"
                              : "circle.fill")
                            .font(.system(size: 8, weight: .semibold))
                            .foregroundStyle(note.localizedCaseInsensitiveContains("fail")
                                             || note.localizedCaseInsensitiveContains("ended")
                                             ? Color.orange
                                             : ColorPalette.accent)
                            .frame(width: 14, height: 18)
                        Text(note)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                        Spacer(minLength: 0)
                    }
                    .padding(.horizontal, 10)
                    .padding(.vertical, 8)
                    .rowSurface()
                }
            }
        }
    }

    private var stream: some View {
        VStack(alignment: .leading, spacing: 6) {
            SectionLabel("Stream")
            Button(action: onShowSources) {
                HStack(spacing: 10) {
                    Image(systemName: "rectangle.on.rectangle")
                        .font(.system(size: 15, weight: .medium))
                        .foregroundStyle(ColorPalette.ink)
                    Text("Display, app or window")
                        .font(.subheadline.weight(.medium))
                    Spacer(minLength: 8)
                    Image(systemName: "chevron.right")
                        .font(.caption)
                        .foregroundStyle(.tertiary)
                }
                .padding(.horizontal, 10)
                .padding(.vertical, 9)
                .rowSurface()
                .contentShape(Rectangle())
            }
            .buttonStyle(RailButtonStyle(scale: 0.98))

            quality

            HStack(spacing: 10) {
                Image(systemName: hevcSupported ? "checkmark.seal.fill" : "xmark.seal")
                    .font(.system(size: 15, weight: .medium))
                    .foregroundStyle(hevcSupported ? Color.green : Color.orange)
                VStack(alignment: .leading, spacing: 1) {
                    Text(hevcSupported ? "HEVC supported" : "HEVC not supported")
                        .font(.subheadline.weight(.medium))
                    Text(hevcSupported
                         ? "This device can decode H.265. Enable HEVC on the Mac for better quality at lower bandwidth."
                         : "This device cannot hardware-decode H.265. Use H.264 on the Mac for best performance.")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 9)
            .rowSurface()
        }
    }

    /// Who picks the picture's bitrate: the app, or the person watching it.
    ///
    /// The status bar has offered the same four presets in one menu since it was a segmented row
    /// that did not fit, and in that list "Auto" reads as the fourth rung of a ladder rather than
    /// as the other answer to the question. The question has two answers and one of them has
    /// three settings under it, so that is what this draws: a mode, and a level that appears only
    /// beneath the mode that has levels. A row of three rates under "Automatic" would be a
    /// control wired to nothing.
    ///
    /// The chip stays as it is. Four presets in a menu and a mode with three levels are the same
    /// four states, and the chip is the faster way to reach one mid-session.
    private var quality: some View {
        VStack(alignment: .leading, spacing: 6) {
            Picker("Quality", selection: Binding(
                get: { !model.isAutomaticQuality },
                set: { model.setAutomaticQuality(!$0) }
            )) {
                Text("Automatic").tag(false)
                Text("Manual").tag(true)
            }
            .pickerStyle(.segmented)
            .accessibilityLabel("Stream quality mode")

            if !model.isAutomaticQuality {
                Picker("Level", selection: Binding(
                    get: { model.streamQuality },
                    set: { model.setStreamQuality($0) }
                )) {
                    ForEach(SessionModel.StreamQuality.manualCases, id: \.self) { preset in
                        Text(preset.title).tag(preset)
                    }
                }
                .pickerStyle(.segmented)
                .accessibilityLabel("Stream quality level")
            }

            Text(qualityExplanation)
                .font(.caption2)
                .foregroundStyle(.tertiary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    /// What the two modes do to the picture, in the words the numbers need.
    ///
    /// Both branches carry the figures, because "Manual" alone is not a setting anyone can weigh:
    /// the choice being made is how much of the connection to spend on the picture, and the
    /// presets on their own name a rung on a ladder the user has never been shown.
    private var qualityExplanation: String {
        guard !model.isAutomaticQuality else {
            return """
                Peering picks the rate and moves it as the connection does: down when frames \
                arrive late or are dropped, up again after a stretch of clean ones. Low is \
                2 Mbps, Medium is 8, High is 20.
                """
        }
        let mbps = (model.streamQuality.bitrateKbps ?? 0) / 1_000
        return """
            The Mac sends the picture at \(mbps) Mbps and holds that rate whatever the network \
            does. A connection with less room than this to spare shows it as stutter rather \
            than as a softer picture — Low is 2 Mbps, Medium is 8, High is 20.
            """
    }

    private var panels: some View {
        VStack(alignment: .leading, spacing: 6) {
            SectionLabel("Panels")
            Toggle(isOn: $hidesPanelAfterSelect) {
                Text("Close after selecting")
                    .font(.subheadline.weight(.medium))
            }
            .tint(ColorPalette.accent)
            Text("""
                Desktops and sources put themselves away once you have picked one. Shortcuts \
                stays open either way. Its buttons are key presses rather than choices, and a \
                panel that shut after every one would have to be reopened for the next.
                """)
                .font(.caption2)
                .foregroundStyle(.tertiary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    /// The floating window, and whether it arrives on its own.
    private var picture: some View {
        VStack(alignment: .leading, spacing: 6) {
            SectionLabel("Picture")
            Toggle(isOn: $pipAutoStart) {
                Text("Float automatically")
                    .font(.subheadline.weight(.medium))
            }
            .tint(ColorPalette.accent)
            // Pushed straight through rather than read on the next attach: the setting has to
            // take effect on the controller that is already running.
            .onChange(of: pipAutoStart) { _, on in SessionPiP.shared.autoStart = on }

            // The manual start, which used to be a dot in the status bar and did not earn one:
            // iOS floats the picture by itself on the way out, so the button started something
            // that had already happened. What it is actually for is trying it *without* leaving,
            // and for getting a refusal in writing — which is a diagnostic, and this is where the
            // switch it explains lives.
            Button {
                SessionPiP.shared.start()
            } label: {
                Label("Try it now", systemImage: "pip")
                    .font(.subheadline.weight(.medium))
            }
            .buttonStyle(.bordered)
            .controlSize(.small)
            .disabled(!SessionPiP.isSupported)

            Text("Leaving the app floats the picture over whatever is next. iOS has its own switch for this under Settings, General, Picture in Picture, and both have to allow it. \"Try it now\" starts it without leaving.")
                .font(.caption2)
                .foregroundStyle(.tertiary)
                .fixedSize(horizontal: false, vertical: true)

            // What iOS said the last time it was asked. It used to sit in the session's status
            // bar, where it was a line of AVKit's own words in the middle of the picture — read
            // by nobody, and in the way of the controls. Here it is next to the button that asks
            // the question, which is the only place it means anything.
            if let attempt = SessionPiP.shared.lastAttempt {
                VStack(alignment: .leading, spacing: 2) {
                    Text("Last attempt: \(attempt)")
                        .font(.caption2.weight(.semibold))
                        .foregroundStyle(.secondary)
                    if let why = SessionPiP.shared.lastRefusal {
                        Text(why)
                            .font(.caption2)
                            .foregroundStyle(.tertiary)
                            .fixedSize(horizontal: false, vertical: true)
                            .textSelection(.enabled)
                    }
                }
            }
        }
    }

    /// The one switch here that is about what leaves the device rather than how the app looks.
    ///
    /// Written out in full rather than left as a bare label, because a privacy setting the user
    /// cannot understand is a setting they cannot make. This is the switch; ``FAQView`` is the
    /// why, at length. Both have to say the same thing, and neither may say more than is true:
    /// the relay cannot read what it carries, and it does see who is connecting and when.
    private var privacy: some View {
        VStack(alignment: .leading, spacing: 6) {
            SectionLabel("Privacy")
            Toggle(isOn: $allowsRelay) {
                Text("Allow the relay")
                    .font(.subheadline.weight(.medium))
            }
            .tint(ColorPalette.accent)
            Text("""
                On: when your Mac is not on this network, Peering reaches it through a relay \
                server. The connection is still end-to-end encrypted and the relay cannot read \
                it, but the Mac's device ID and the times you connect do pass through that server.

                Off: Peering only ever connects directly, over the network the two of you are \
                both on. A Mac somewhere else is not reachable at all, and the app waits for it \
                to come back rather than failing.
                """)
                .font(.caption2)
                .foregroundStyle(.tertiary)
                .fixedSize(horizontal: false, vertical: true)
            Toggle(isOn: Binding(
                get: { model.privacyModeEnabled },
                set: { model.setPrivacyMode($0) }
            )) {
                Text("Darken the Mac's displays")
                    .font(.subheadline.weight(.medium))
            }
            .tint(ColorPalette.accent)
            Text("Privacy Mode sets supported displays to 0% brightness without stopping the stream. Brightness is restored when you turn it off or disconnect. The Mac's physical brightness-up key always remains an escape hatch.")
                .font(.caption2)
                .foregroundStyle(.tertiary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private var keyboard: some View {
        VStack(alignment: .leading, spacing: 6) {
            SectionLabel("Keyboard")
            Picker("Mode", selection: Binding(
                get: { model.keyboardMode },
                set: { model.setKeyboardMode($0) }
            )) {
                ForEach(KeyboardMode.allCases) { mode in
                    Text(mode.label).tag(mode)
                }
            }
            .pickerStyle(.segmented)
            Text(model.keyboardMode.explanation)
                .font(.caption2)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private var macros: some View {
        VStack(alignment: .leading, spacing: 6) {
            SectionLabel("Macros")
            // Scrolls sideways rather than wrapping: the macros are a fixed, short list, and a
            // wrapped grid would change the panel's height every time a title did.
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 6) {
                    ForEach(Macro.defaults) { macro in
                        Button { model.run(macro) } label: {
                            Text(macro.title)
                                .font(.caption.weight(.medium))
                                .lineLimit(1)
                                .padding(.horizontal, 10)
                                .padding(.vertical, 7)
                                .rowSurface()
                        }
                        .buttonStyle(RailButtonStyle(scale: 0.94))
                    }
                }
                .padding(.vertical, 2)
            }
        }
    }

    @ViewBuilder
    private var pairedMacs: some View {
        if !model.pairedHostIDs.isEmpty {
            VStack(alignment: .leading, spacing: 6) {
                SectionLabel("Paired Macs")
                ForEach(model.pairedHostIDs, id: \.self) { hostID in
                    HStack(spacing: 8) {
                        Text(hostID)
                            .font(.caption2.monospaced())
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                            .truncationMode(.middle)
                        Spacer(minLength: 8)
                        Button("Forget", role: .destructive) { model.forget(hostID: hostID) }
                            .font(.caption.weight(.semibold))
                            .foregroundStyle(.secondary)
                            .buttonStyle(RailButtonStyle())
                    }
                }
            }
        }
    }

    private var thisDevice: some View {
        VStack(alignment: .leading, spacing: 6) {
            SectionLabel("This device")
            HStack(spacing: 10) {
                Image(systemName: "iphone")
                    .font(.system(size: 15, weight: .medium))
                    .foregroundStyle(ColorPalette.ink)
                Text("Device name")
                    .font(.subheadline.weight(.medium))
                Spacer(minLength: 8)
                TextField("Name shown to Mac", text: Binding(
                    get: { model.device.name },
                    set: { model.setDeviceName($0) }
                ))
                .font(.subheadline)
                .multilineTextAlignment(.trailing)
                .foregroundStyle(.secondary)
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 9)
            .rowSurface()
            Text("The name Macs see for this device. iOS 16+ restricts apps from reading your custom device name without a special entitlement, so setting it here ensures Macs show the right name.")
                .font(.caption2)
                .foregroundStyle(.tertiary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private func info(_ title: String, _ value: String) -> some View {
        HStack(spacing: 8) {
            Text(title)
                .font(.caption)
                .foregroundStyle(.secondary)
            Spacer(minLength: 8)
            Text(value)
                .font(.caption.weight(.medium))
                .lineLimit(1)
                .truncationMode(.middle)
        }
    }

    private var stateDescription: String {
        switch model.phase {
        case .idle: return "Idle"
        case .connecting: return "Connecting"
        case .handshaking: return "Handshaking"
        case .confirming: return "Waiting for the code comparison"
        case .ready: return "Connected"
        case .failed(let message): return "Failed: \(message)"
        case .disconnected: return model.isReconnecting ? "Offline · reconnecting…" : "Disconnected"
        }
    }
}
