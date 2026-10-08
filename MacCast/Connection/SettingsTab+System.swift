import MacCastKit
import MessageUI
import RemoteCore
import SSHCore
import SwiftUI
import UIKit

extension SettingsTab {
    /// On a plan without it the switch is dimmed and inert with the plan's name overlaid at the corner: an overlay costs no width, so the row does not move when the plan changes.
    var pipSection: some View {
        Controls.card(
            String(localized: "Picture in Picture"),
            footer: model.storeManager.access.includes(.pictureInPicture)
                ? String(localized: "Peering can keep a live view of your Mac floating over other apps.")
                : String(localized: "It is part of \(PlanCapability.pictureInPicture.minimumPlan.name), with sound from the Mac and files that move both ways.")
        ) {
            PlanLocked(capability: .pictureInPicture, title: "Float automatically") {
                Controls.toggle(String(localized: "Float automatically"), systemImage: "pip", isOn: $pipAutoStart)
                    .onChange(of: pipAutoStart) { _, on in model.setPiPAutoStart(on) }
            }
        }
    }

    var homeScreenWidgetSection: some View {
        Controls.card(
            String(localized: "Home Screen widget"),
            footer: String(localized: "Add Peering from the widget gallery for one-tap access to your last Mac.")
        ) {
            HomeScreenWidgetPreview(
                hostNames: model.pairedHostIDs.prefix(3).map {
                    model.displayName(forHostID: $0) ?? String(localized: "A Mac")
                }
            )
            .padding(.vertical, 5)
        }
    }

    var liveActivitySection: some View {
        Controls.card(
            String(localized: "Live Activity"),
            footer: String(localized: "Shows session status and duration on the Lock Screen and in Dynamic Island.")
        ) {
            Controls.toggle(String(localized: "Show live activity"), systemImage: "lock.fill", isOn: $liveActivitiesEnabled)
                .onChange(of: liveActivitiesEnabled) { _, enabled in
                    SessionActivity.shared.preferenceChanged(enabled: enabled)
                }

            Controls.divider

            VStack(alignment: .leading, spacing: 10) {
                Text("Lock Screen preview")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.secondary)
                LockScreenWidgetPreview()
                    .opacity(liveActivitiesEnabled ? 1 : 0.45)
            }
            .padding(.vertical, 4)
        }
    }

    /// Not a control: there is nothing to switch, the banner is raised because a shell stopped. The state printed is the system permission, not our preference; a row saying On beside a refused permission would claim something the app cannot do. On a plan without it the tap opens the paywall through ``PlanLocked``.
    var notificationsSection: some View {
        let included = model.storeManager.access.includes(.terminalAlerts)

        return Controls.card(
            String(localized: "Notifications"),
            footer: included
                ? String(localized: "A shell that stops for an answer puts a banner up while Peering is not in front of you, on this device and through the Mac when no session is open. iOS carries the permission under Settings, Notifications, Peering.")
                : String(localized: "Being told when a terminal needs you is part of \(PlanCapability.terminalAlerts.minimumPlan.name), with sound from the Mac, Picture in Picture and files that move both ways.")
        ) {
            PlanLocked(capability: .terminalAlerts, title: String(localized: "Told when a shell needs you")) {
                Controls.row(String(localized: "Terminal needs you"), systemImage: "bell.badge") {
                    Text(model.notificationsAuthorized ? "On" : "Off")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                }
            }

            Controls.divider

            // The device's half of the same question: a Mac reaches this phone with no session through a push to a token iOS gives it, and a missing token looks from the Mac like a failed send. A reason is shown when there is one, as the only place this failure is visible.
            Controls.row(String(localized: "This phone can be reached"), systemImage: "antenna.radiowaves.left.and.right") {
                Text(model.pushRegistration ?? "No")
                    .font(.subheadline)
                    .foregroundStyle(model.pushRegistration == nil ? .secondary : ColorPalette.caution)
            }
        }
    }
}
