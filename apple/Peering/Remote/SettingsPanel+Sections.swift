import PeeringKit
import RemoteCore
import SwiftUI
import VideoToolbox

extension SettingsPanel {
    /// A privacy setting the user cannot understand is one they cannot make; ``FAQView`` has the why. Both must say the same and nothing untrue: the relay cannot read what it carries and does see who connects and when.
    var privacy: some View {
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

    var keyboard: some View {
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

    var macros: some View {
        VStack(alignment: .leading, spacing: 6) {
            SectionLabel(String(localized: "Macros"))
            // Scrolls sideways: a wrapped grid would change the panel's height whenever a title did.
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 6) {
                    ForEach(Macro.defaults(for: model.hostPlatform)) { macro in
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
    var pairedMacs: some View {
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

    var thisDevice: some View {
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

    func info(_ title: String, _ value: String) -> some View {
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

    var stateDescription: String {
        switch model.phase {
        case .idle: return String(localized: "Idle")
        case .connecting: return String(localized: "Connecting")
        case .handshaking: return String(localized: "Handshaking")
        case .confirming: return String(localized: "Waiting for the code comparison")
        case .ready: return String(localized: "Connected")
        case .failed(let message): return String(localized: "Failed: \(HostWireText.localized(message))")
        case .disconnected: return model.isReconnecting ? String(localized: "Offline · reconnecting…") : String(localized: "Disconnected")
        }
    }
}
