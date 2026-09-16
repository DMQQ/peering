import RemoteCore
import SwiftUI

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

    @State private var confirmReset = false
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
                stream
                picture
                panels
                privacy
                keyboard
                macros
                pairedMacs
                reset
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(10)
        .glassEffect(.regular, in: RoundedRectangle(cornerRadius: 22, style: .continuous))
        .padding(.horizontal, 10)
        .reportChromeFrame(.panel, into: $chromeFrames)
        .transition(.move(edge: .bottom).combined(with: .opacity))
        .confirmationDialog(
            "Reset this device's identity?",
            isPresented: $confirmReset,
            titleVisibility: .visible
        ) {
            Button("Reset", role: .destructive) { model.resetDeviceIdentity() }
        } message: {
            Text("Every Mac you have paired with will treat this device as a new one.")
        }
        .confirmationDialog(
            "Lock this Mac?",
            isPresented: $confirmLock,
            titleVisibility: .visible
        ) {
            Button("Lock Mac", role: .destructive) { model.lockMac() }
        } message: {
            Text("You will need to unlock it locally with its password, Touch ID, or Apple Watch.")
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
                Label("Lock Mac", systemImage: "lock.fill")
                    .font(.subheadline.weight(.semibold))
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 9)
                    .rowSurface()
                    .contentShape(Rectangle())
            }
            .buttonStyle(RailButtonStyle(scale: 0.98))
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
        }
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
            Text("Leaving the app floats the picture over whatever is next. The button in the status bar starts it by hand either way, and iOS has its own switch for this under Settings, General, Picture in Picture. Both have to allow it.")
                .font(.caption2)
                .foregroundStyle(.tertiary)
                .fixedSize(horizontal: false, vertical: true)
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

    private var reset: some View {
        VStack(alignment: .leading, spacing: 6) {
            SectionLabel("This device")
            Button(role: .destructive) { confirmReset = true } label: {
                Text("Reset identity")
                    .font(.subheadline.weight(.medium))
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 9)
                    .rowSurface()
                    .contentShape(Rectangle())
            }
            .buttonStyle(RailButtonStyle(scale: 0.98))
            Text("Generates a new key and a new device ID. Every Mac that knows this device must pair with it again.")
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
        case .disconnected: return "Disconnected"
        }
    }
}
