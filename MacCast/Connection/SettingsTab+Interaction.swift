import MacCastKit
import MessageUI
import RemoteCore
import SSHCore
import SwiftUI
import UIKit

extension SettingsTab {
    func shows(_ section: SettingsSearch.Section) -> Bool {
        SettingsSearch.matches(section, query)
    }

    var deviceSection: some View {
        Controls.card(
            String(localized: "This device"),
            footer: String(localized: "The name shown to Macs when you connect. Tap the name to edit it.")
        ) {
            Controls.row(String(localized: "Device name"), systemImage: AdaptiveLayout.deviceSymbol) {
                TextField("Name shown to Macs", text: $deviceNameDraft)
                    .multilineTextAlignment(.trailing)
                    .foregroundStyle(.secondary)
                    .textInputAutocapitalization(.words)
                    .submitLabel(.done)
                    .focused($deviceNameFocused)
                    .onSubmit {
                        commitDeviceName()
                        deviceNameFocused = false
                    }
            }
        }
    }

    var controlsSection: some View {
        Controls.card(String(localized: "Session controls"), footer: model.keyboardMode.explanation) {
            Controls.picker(String(localized: "Interaction"), systemImage: "hand.point.up.left", selection: $interactionMode) {
                ForEach(InteractionMode.allCases) { mode in
                    Text(mode == .control ? "Control" : "Observe").tag(mode)
                }
            }

            Controls.divider

            // Answers are two words each, a layout constraint: a menu picker wraps rather than truncating, and "Fit whole screen" took two lines and pushed the chevron aside.
            Controls.picker(
                String(localized: "Picture"),
                systemImage: "arrow.up.left.and.arrow.down.right",
                selection: $scalesToFill
            ) {
                Text("Fit screen").tag(false)
                Text("Fill screen").tag(true)
            }

            Controls.divider

            Controls.picker(String(localized: "Keyboard"), systemImage: "keyboard", selection: Binding(
                get: { model.keyboardMode },
                set: { model.setKeyboardMode($0) }
            )) {
                ForEach(KeyboardMode.allCases) { mode in
                    Text(mode.label).tag(mode)
                }
            }

            Controls.divider

            Controls.toggle(
                String(localized: "Open keyboard for text fields"),
                systemImage: "keyboard.badge.ellipsis",
                isOn: $opensKeyboardForTextFields
            )

            Controls.divider

            Controls.toggle(
                String(localized: "Close panels after selecting"),
                systemImage: "rectangle.on.rectangle",
                isOn: $hidesPanelAfterSelect
            )
        }
    }

    /// Here because the control otherwise exists only inside a running session, which this tab cannot be open during. It writes a preference and tells nobody: there is no connection to send it over, and ``SessionModel`` reads it back when a session arrives.
    /// A `Menu` rather than ``Controls/picker(_:systemImage:selection:options:)``: a picker prints the option on the trailing edge and wraps, and these options carry their bitrate. The row shows the short name and the popup ``StreamQuality/menuTitle``, as the speed chip does.
    var qualitySection: some View {
        Controls.card(String(localized: "Stream quality"),
            footer: String(localized: "The level a session starts at. Changing it during a session changes this too, so the next one starts where you left off.")
        ) {
            Controls.row(String(localized: "Quality"), systemImage: "speedometer") {
                Menu {
                    ForEach(SessionModel.StreamQuality.allCases, id: \.self) { preset in
                        Button {
                            streamQuality = preset
                        } label: {
                            if preset == streamQuality {
                                Label(preset.menuTitle, systemImage: "checkmark")
                            } else {
                                Text(preset.menuTitle)
                            }
                        }
                    }
                } label: {
                    HStack(spacing: 6) {
                        Text(streamQuality.title)
                            .foregroundStyle(.secondary)
                        Image(systemName: "chevron.up.chevron.down")
                            .font(.system(size: 11, weight: .semibold))
                            .foregroundStyle(.tertiary)
                    }
                }
                .tint(.white.opacity(0.72))
                .font(.subheadline)
                .accessibilityLabel("Stream quality")
                .accessibilityValue(streamQuality.title)
            }
        }
    }
}
