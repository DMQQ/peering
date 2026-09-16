import AppKit
import RemoteCore
import SwiftUI

/// What a trusted phone can do, and what this app is.
///
/// An extension on the window rather than a type of its own — the state is the
/// window's, and the window is easier to read in pieces than as one file of
/// fifteen hundred lines.
extension HostStatusView {
    /// What pairing actually grants, said plainly.
    ///
    /// Worth the space: "trusted device" is a phrase that sounds broader than it is, and the
    /// honest answer — it can see the screen you chose and send input — is both narrower and
    /// easier to reason about than a phrase like "full access".
    var privacyNote: some View {
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

    func privacyRow(_ title: String, _ detail: String) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(title).font(.subheadline.weight(.medium))
            Text(detail)
                .font(.caption)
                .foregroundStyle(HostPalette.muted)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    // MARK: - About

    var aboutSection: some View {
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
}
