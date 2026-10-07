import MacCastKit
import RemoteCore
import SwiftUI
import VideoToolbox

/// A `List` brings its own background, separators and insets, chosen for a full-screen display, and does not survive on top of live video.
struct SettingsPanel: View {
    @Environment(SessionModel.self) private var model

    @Binding var chromeFrames: [ChromeRegion: CGRect]

    var onShowSources: () -> Void

    @State private var confirmLock = false

    /// Read here as well as in the screen that obeys it, under one key in ``PreferenceKey``: two spellings would be a switch that does nothing for one.
    @AppStorage(PreferenceKeys.hidesPanelAfterSelect) private var hidesPanelAfterSelect = true
    @AppStorage(PreferenceKeys.pipAutoStart) private var pipAutoStart = true
    @AppStorage(PreferenceKeys.allowRelay) private var allowsRelay = true
    @AppStorage(PreferenceKeys.opensKeyboardForTextFields) private var opensKeyboardForTextFields = true
    @State private var query = ""

    private func shows(_ section: SettingsSearch.Section) -> Bool {
        SettingsSearch.matches(section, query)
    }

    var body: some View {
        ScrollView(.vertical, showsIndicators: false) {
            VStack(alignment: .leading, spacing: 16) {
                SettingsSearchField(query: $query)
                if shows(.sessionInfo) { session }
                if shows(.activity) { activity }
                if shows(.stream) { stream }
                if shows(.sessionPicture) { picture }
                if shows(.sessionPanels) { panels }
                if shows(.privacy) { privacy }
                if shows(.sessionKeyboard) { keyboard }
                if shows(.macros) { macros }
                if shows(.pairedMacs) { pairedMacs }
                if shows(.thisDevice) { thisDevice }
                if SettingsSearch.hasNoMatch(query, in: SettingsSearch.panelSections) {
                    SettingsSearch.noResults(query)
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(10)
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
            SectionLabel(String(localized: "Session"))
            info("Mac", model.hostName ?? String(localized: "None"))
            info(String(localized: "State"), stateDescription)
            info("Path", model.connectionPath?.rawValue ?? "None")
            // Only when worth reading: a direct session has nothing to explain.
            if !model.usedDirectPath {
                info(String(localized: "Direct path"), model.directPathStatus.summary)
            }
            info(String(localized: "Video"), model.videoStatus)
            // Two rows, because the control connection goes through the relay in every session, so its round trip is the relay's even when the video went straight; one "Latency" row made punched sessions look slower than they are.
            if let path = model.pathLatencyMilliseconds {
                info(
                    model.pathLatencyIsDirect ? String(localized: "Latency · direct") : String(localized: "Latency · relay"),
                    "\(Int(path.rounded())) ms"
                )
            }
            if let latency = model.latencyMilliseconds {
                info(String(localized: "Latency · control"), "\(Int(latency.rounded())) ms")
            }
            info(String(localized: "This device"), model.thisDeviceDescription)
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
            SectionLabel(String(localized: "Recent activity"))
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
            SectionLabel(String(localized: "Stream"))
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

            // Its own row: what the picture costs and what you hear are two decisions, and this is the one reached for mid-session.
            // The switch is the switch on every plan: dimmed and inert without the capability, and the tap opens the plans. A padlock in its place left a row whose control could have been anything.
            PlanLocked(capability: .macSound, title: String(localized: "Sound from the Mac")) {
                Toggle(isOn: Binding(
                    get: { !model.hostAudioMuted },
                    set: { model.hostAudioMuted = $0 }
                )) {
                    Text("Sound from the Mac")
                        .font(.subheadline.weight(.medium))
                }
                .tint(ColorPalette.accent)
            }

            if model.storeManager.access.includes(.macSound) {
                Text(model.hostAudioMuted
                     ? "The Mac's audio is still sent, and dropped here without being played."
                     : "Whatever the Mac plays comes out of this device, including the sounds it makes in answer to what you send it.")
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
                    .fixedSize(horizontal: false, vertical: true)
            } else {
                // The plan-aware sentence is the only thing the locked state adds: which plan turns it on.
                Text("Whatever the Mac plays would come out of this device. It is part of \(PlanCapability.macSound.minimumPlan.name), along with Picture in Picture and files that move both ways.")
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
                    .fixedSize(horizontal: false, vertical: true)
            }

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

    /// "Auto" read as the fourth rung of a ladder; the question has two answers and one has three settings under it, so this draws a mode and a level shown only under the mode that has levels.
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

    /// Both branches carry the figures: "Manual" alone is not a setting anyone can weigh.
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
            than as a softer picture: Low is 2 Mbps, Medium is 8, High is 20.
            """
    }

    private var panels: some View {
        VStack(alignment: .leading, spacing: 6) {
            SectionLabel(String(localized: "Panels"))
            Toggle(isOn: $hidesPanelAfterSelect) {
                Text("Close after selecting")
                    .font(.subheadline.weight(.medium))
            }
            .tint(ColorPalette.accent)
            Text("""
                The Apps panel puts itself away once you have picked a source, a desktop or an \
                application. Shortcuts stays open either way. Its buttons are key presses rather \
                than choices, and a panel that shut after every one would have to be reopened \
                for the next.
                """)
                .font(.caption2)
                .foregroundStyle(.tertiary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private var picture: some View {
        VStack(alignment: .leading, spacing: 6) {
            SectionLabel(String(localized: "Picture"))

            PlanLocked(capability: .pictureInPicture, title: String(localized: "Float automatically")) {
                Toggle(isOn: $pipAutoStart) {
                    Text("Float automatically")
                        .font(.subheadline.weight(.medium))
                }
                .tint(ColorPalette.accent)
                // Pushed straight through: the controller that is already running must pick it up.
                .onChange(of: pipAutoStart) { _, on in model.setPiPAutoStart(on) }
            }

            if model.storeManager.access.includes(.pictureInPicture) {
                Text("Leaving the app floats the picture over whatever is next. iOS has its own switch for this under Settings, General, Picture in Picture, and both have to allow it.")
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
                    .fixedSize(horizontal: false, vertical: true)
            } else {
                Text("Leaving the app would keep the Mac's screen floating over whatever is next, and iOS has a switch of its own for it under Settings, General, Picture in Picture. Both of them are part of \(PlanCapability.pictureInPicture.minimumPlan.name).")
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    /// A privacy setting the user cannot understand is one they cannot make; ``FAQView`` has the why. Both must say the same and nothing untrue: the relay cannot read what it carries and does see who connects and when.
    private var privacy: some View {
        VStack(alignment: .leading, spacing: 6) {
            SectionLabel(String(localized: "Privacy"))
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
            Text("Privacy Mode darkens the Mac's displays without stopping the stream. Displays whose brightness macOS can set go to 0%; any it cannot are covered by a black screen. Either way everything is restored when you turn it off or disconnect. The Mac's physical brightness-up key still brings a dimmed display back.")
                .font(.caption2)
                .foregroundStyle(.tertiary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private var keyboard: some View {
        VStack(alignment: .leading, spacing: 6) {
            SectionLabel(String(localized: "Keyboard"))
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
            Toggle(isOn: $opensKeyboardForTextFields) {
                Text("Open for text fields")
                    .font(.subheadline.weight(.medium))
            }
            .tint(ColorPalette.accent)
            .padding(.top, 4)
            Text("The keyboard opens when you click into a text field on the Mac, and closes when you click out of it, unless you opened it yourself.")
                .font(.caption2)
                .foregroundStyle(.tertiary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private var macros: some View {
        VStack(alignment: .leading, spacing: 6) {
            SectionLabel(String(localized: "Macros"))
            // Scrolls sideways: a wrapped grid would change the panel's height whenever a title did.
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
                SectionLabel(String(localized: "Paired Macs"))
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
            SectionLabel(String(localized: "This device"))
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
        case .idle: return String(localized: "Idle")
        case .connecting: return String(localized: "Connecting")
        case .handshaking: return String(localized: "Handshaking")
        case .confirming: return String(localized: "Waiting for the code comparison")
        case .ready: return "Connected"
        case .failed(let message): return String(localized: "Failed: \(message)")
        case .disconnected: return model.isReconnecting ? String(localized: "Offline · reconnecting…") : String(localized: "Disconnected")
        }
    }
}
