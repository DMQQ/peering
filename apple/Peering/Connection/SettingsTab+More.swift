import PeeringKit
import MessageUI
import RemoteCore
import SSHCore
import SwiftUI
import UIKit

extension SettingsTab {
#if DEBUG
    /// Behind `#if DEBUG`: not in any build a user receives (`Tools/install-iphone.sh` builds Debug). It changes the app and not the wire: gates read ``StoreManager/access``, which this overrides, while a session still states ``StoreManager/relayPlan`` from the real entitlement, so it cannot be used to spend relay allowance.
    var developerSection: some View {
        Controls.card(
            String(localized: "Developer"),
            footer: String(localized: """
                Changes what this app shows, not what the relay is told: sessions stay metered at \
                whatever this Apple Account pays for.
                """)
        ) {
            Controls.row(String(localized: "Plan override"), systemImage: "hammer") {
                Menu {
                    Button("Off") { model.storeManager.setPlanOverride(nil) }
                    ForEach(RelayPlan.allCases, id: \.self) { plan in
                        Button {
                            model.storeManager.setPlanOverride(plan)
                        } label: {
                            if model.storeManager.planOverride == plan {
                                Label(plan.name, systemImage: "checkmark")
                            } else {
                                Text(plan.name)
                            }
                        }
                    }
                } label: {
                    HStack(spacing: 6) {
                        Text(model.storeManager.planOverride?.name ?? String(localized: "Real"))
                            .foregroundStyle(model.storeManager.planOverride == nil ? .secondary : .primary)
                        Image(systemName: "chevron.up.chevron.down")
                            .font(.system(size: 11, weight: .semibold))
                            .foregroundStyle(.tertiary)
                    }
                }
                .tint(.white.opacity(0.72))
                .font(.subheadline)
                .accessibilityLabel("Plan override")
                .accessibilityValue(model.storeManager.planOverride?.name ?? String(localized: "Real"))
            }
        }
    }
#endif

    var moreSection: some View {
        Controls.card(String(localized: "More")) {
            // First: the Mac app is a download, so someone setting up another machine has to come back here for it.
            Link(destination: PeeringSite.download) {
                Controls.row(String(localized: "Peering for Mac"), systemImage: "arrow.down.circle") {
                    Image(systemName: "arrow.up.right")
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(.tertiary)
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(RailButtonStyle(scale: 0.99))
            .foregroundStyle(ColorPalette.ink)

            Controls.divider

            Button {
                hasSeenWelcome = false
            } label: {
                Controls.row(String(localized: "Show introduction again"), systemImage: "rectangle.stack") {
                    Image(systemName: "chevron.right")
                        .font(.caption)
                        .foregroundStyle(.tertiary)
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(RailButtonStyle(scale: 0.99))

            Controls.divider

            // All five tours reset, with no way to pick: a skipped tip may have been read or dismissed mid-task, and the person who skipped it does not remember which.
            Button {
                Tour.resetAll()
            } label: {
                Controls.row(String(localized: "Show tips again"), systemImage: "lightbulb") {
                    Image(systemName: "chevron.right")
                        .font(.caption)
                        .foregroundStyle(.tertiary)
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(RailButtonStyle(scale: 0.99))

            Controls.divider

            // There is no analytics or crash reporting, so a report and an App Store review are the whole of the feedback. Diagnostics ride along as an attachment inside a draft the user can read and strip. `mailto:` cannot carry an attachment, so this opens Apple's compose sheet; with no Mail account it falls back to the plain link, unattached.
            Button {
                if MFMailComposeViewController.canSendMail() {
                    showingMailComposer = true
                } else {
                    openURL(Self.reportURL)
                }
            } label: {
                Controls.row(String(localized: "Report an issue"), systemImage: "envelope") {
                    Image(systemName: "arrow.up.right")
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(.tertiary)
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(RailButtonStyle(scale: 0.99))
            .foregroundStyle(ColorPalette.ink)
            .sheet(isPresented: $showingMailComposer) {
                MailComposer(
                    recipient: "support@getpeering.app",
                    subject: String(localized: "Peering issue"),
                    body: Self.reportBody,
                    attachment: (Data(Diagnostics.text(model: model).utf8), "text/plain", "diagnostics.txt"),
                    onFinish: { showingMailComposer = false }
                )
                .ignoresSafeArea()
            }

            Controls.divider

            Button {
                if let url = URL(string: "https://github.com/DMQQ/peering") { openURL(url) }
            } label: {
                Controls.row(String(localized: "Source code on GitHub", table: "Chrome"), systemImage: "chevron.left.forwardslash.chevron.right") {
                    Image(systemName: "arrow.up.right")
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(.tertiary)
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(RailButtonStyle(scale: 0.99))
            .foregroundStyle(ColorPalette.ink)

            Controls.divider

            Button {
                UIPasteboard.general.string = Diagnostics.text(model: model)
                copiedDiagnostics = true
                Task {
                    try? await Task.sleep(for: .seconds(2))
                    copiedDiagnostics = false
                }
            } label: {
                Controls.row(
                    String(localized: "Copy diagnostics"),
                    systemImage: copiedDiagnostics ? "checkmark" : "doc.on.doc"
                ) {
                    Text(copiedDiagnostics ? "Copied" : "")
                        .font(.caption.weight(.medium))
                        .foregroundStyle(copiedDiagnostics ? ColorPalette.accent : Color.secondary)
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(RailButtonStyle(scale: 0.99))
            .foregroundStyle(ColorPalette.ink)
        }
    }

    /// A card of its own at the bottom. Both open in the browser, not a web view: a page inside the app would be a second copy of a document that must match the App Store listing's.
    var legalSection: some View {
        Controls.card(String(localized: "Legal")) {
            externalLink(String(localized: "Privacy policy"), systemImage: "hand.raised", to: PeeringSite.privacy)

            Controls.divider

            externalLink(String(localized: "Terms of use"), systemImage: "doc.text", to: PeeringSite.terms)
        }
    }

    private func externalLink(_ title: String, systemImage: String, to url: URL) -> some View {
        Link(destination: url) {
            Controls.row(title, systemImage: systemImage) {
                Image(systemName: "arrow.up.right")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.tertiary)
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(RailButtonStyle(scale: 0.99))
        .foregroundStyle(ColorPalette.ink)
    }

    /// The app version and iOS release are the first things anyone has to ask for. The device ID, plan and path live in the ``Diagnostics`` attachment, not here.
    private static var reportBody: String {
        let info = Bundle.main.infoDictionary
        let version = info?["CFBundleShortVersionString"] as? String ?? "unknown"
        let build = info?["CFBundleVersion"] as? String ?? "unknown"

        return """
            What happened:


            What I expected:


            Peering \(version) (\(build))
            \(ProcessInfo.processInfo.operatingSystemVersionString)
            """
    }

    /// The fallback when no Mail account is configured: `mailto:` has no attachment, so the "Copy diagnostics" row fills that gap by hand.
    private static var reportURL: URL {
        var components = URLComponents()
        components.scheme = "mailto"
        components.path = "support@getpeering.app"
        components.queryItems = [
            URLQueryItem(name: "subject", value: String(localized: "Peering issue")),
            URLQueryItem(name: "body", value: reportBody),
        ]
        return components.url ?? URL(string: "mailto:support@getpeering.app")!
    }

    func commitDeviceName() {
        let trimmed = deviceNameDraft.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            deviceNameDraft = model.device.name
            return
        }
        model.setDeviceName(trimmed)
        deviceNameDraft = model.device.name
    }
}
