import AppKit
import MacCastKit
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
                    "Hear this Mac, and run things on it",
                    "The sound this Mac plays is sent with the picture, and is on by default. A trusted phone can also open a Terminal here as you, list and read files, replace them, launch applications, switch desktops and lock the screen. That is the same reach your own Terminal window has, and it is why the list above is worth reading before you pair."
                )
                Divider()
                privacyRow(
                    "Clipboard, when you ask",
                    // **Files used to be named here as something that is never sent, and they are
                    // sent**, in both directions, up to 64 MB at a time. A privacy screen that
                    // understates what a trusted device can do is worse than no privacy screen,
                    // because it is the one page a reader takes at its word. The microphone and the
                    // camera really are not used, on either device, and saying so is worth keeping.
                    "Clipboard text moves only when you use Pull or Push on the iPhone. Files do move between the two, when you ask them to. No microphone and no camera is used, on either device."
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
    ///
    /// Shared with the menu bar, which offers the same thing: the menu is where this app is
    /// usually being looked at when something has gone wrong, and a bug report that starts with the
    /// user having to find a window first is one that does not get written.
    static var reportURL: URL {
        let info = Bundle.main.infoDictionary
        let version = info?["CFBundleShortVersionString"] as? String ?? "unknown"
        let build = info?["CFBundleVersion"] as? String ?? "unknown"
        // **The last crash, and where the rest of them are.** A `mailto:` body is a URL, and a
        // backtrace in one would be truncated by whichever mail client opened it, so what goes in
        // is the line that identifies the crash: with the version and the date it is enough to tell
        // two reports apart, and the path is where the whole of it can be attached from.
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
            URLQueryItem(name: "subject", value: "Peering issue (Mac)"),
            URLQueryItem(name: "body", value: body),
        ]
        return components.url ?? URL(string: "mailto:support@getpeering.app")!
    }
}
