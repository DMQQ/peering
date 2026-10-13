import AppKit
import PeeringKit
import RemoteCore
import SwiftUI

extension HostStatusView {
    var privacyNote: some View {
        VStack(alignment: .leading, spacing: 12) {
            sectionHeading(String(localized: "What a trusted phone can do"), detail: String(localized: "The whole of it."))

            VStack(alignment: .leading, spacing: 10) {
                privacyRow(
                    String(localized: "See the screen you share"),
                    String(localized: "The captured display, window or application, and the list of things this Mac could capture, which includes window titles, application names and their icons.")
                )
                Divider()
                privacyRow(
                    String(localized: "Send clicks and keystrokes"),
                    String(localized: "Injected through the same mechanism an assistive keyboard uses, which is why the Accessibility permission is required.")
                )
                Divider()
                privacyRow(
                    String(localized: "Hear this Mac, and run things on it"),
                    String(localized: "The sound this Mac plays is sent with the picture, and is on by default. A trusted phone can also open a Terminal here as you, list and read files, replace them, launch applications, switch desktops and lock the screen. That is the same reach your own Terminal window has, and it is why the list above is worth reading before you pair.")
                )
                Divider()
                privacyRow(
                    String(localized: "Clipboard, when you ask"),
                    // Files are sent in both directions, up to 64 MB; the privacy text must not understate what a trusted device can do.
                    String(localized: "Clipboard text moves only when you use Pull or Push on the iPhone. Files do move between the two, when you ask them to. No microphone and no camera is used, on either device.")
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
                .hostCaption()
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
                Link(destination: Self.reportURL) {
                    Label("Report an issue", systemImage: "envelope")
                }

                HostDiagnosticsRow(model: model)
            }
            .controlSize(.large)
        }
    }

    /// Shared with the menu bar. Includes only the app version and macOS release, nothing identifying.
    static var reportURL: URL {
        let info = Bundle.main.infoDictionary
        let version = info?["CFBundleShortVersionString"] as? String ?? "unknown"
        let build = info?["CFBundleVersion"] as? String ?? "unknown"
        // A mailto body is truncated by mail clients, so only the line identifying the last crash goes in.
        let latest = CrashLog.entries(subject: "host").first
        let crash = latest.map { entry in
            """

            Last crash: \(CrashLog.headline(of: entry))
            \(entry.date.formatted(date: .abbreviated, time: .shortened))
            Full reports: ~/Library/Application Support/host/Crashes
            """
        } ?? ""

        let body = """
            What happened:


            What I expected:


            Peering for Mac \(version) (\(build))
            \(ProcessInfo.processInfo.operatingSystemVersionString)\(crash)
            """

        var components = URLComponents()
        components.scheme = "mailto"
        components.path = "support@getpeering.app"
        components.queryItems = [
            URLQueryItem(name: "subject", value: String(localized: "Peering issue (Mac)")),
            URLQueryItem(name: "body", value: body),
        ]
        return components.url ?? URL(string: "mailto:support@getpeering.app")!
    }
}
