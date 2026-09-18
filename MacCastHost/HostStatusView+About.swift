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
                        .font(HostDisplayFont.display(29))
                        .tracking(-0.8)
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

            HStack(spacing: 10) {
                // The same row the iPhone app has, and here because this is the half of the
                // pair that captures the screen: a picture that is black, late or the wrong
                // size is a bug on this Mac, and the report should not have to start with
                // "which app are you using".
                Link(destination: Self.reportURL) {
                    Label("Report an issue", systemImage: "envelope")
                }

                HostDiagnosticsRow(model: model)
            }
            .controlSize(.large)
        }
    }

    /// Where a report goes, with the two facts that make one actionable already in the draft.
    ///
    /// The app version and the macOS release are the first things anyone has to ask for. Neither
    /// identifies the person or the machine: there is no account, and nothing here is a serial
    /// number. Nothing about the session is included either — no Mac name, no device ID.
    private static var reportURL: URL {
        let info = Bundle.main.infoDictionary
        let version = info?["CFBundleShortVersionString"] as? String ?? "unknown"
        let build = info?["CFBundleVersion"] as? String ?? "unknown"
        let body = """
            What happened:


            What I expected:


            Peering for Mac \(version) (\(build))
            \(ProcessInfo.processInfo.operatingSystemVersionString)
            """

        var components = URLComponents()
        components.scheme = "mailto"
        components.path = "support@getpeering.app"
        components.queryItems = [
            URLQueryItem(name: "subject", value: "Peering issue (Mac)"),
            URLQueryItem(name: "body", value: body),
        ]
        return components.url ?? URL(string: "mailto:support@getpeering.app")!
    }
}
