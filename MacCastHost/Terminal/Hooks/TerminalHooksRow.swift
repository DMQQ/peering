import AppKit
import SwiftUI

/// The switch for Claude Code hooks. Turning it on asks first and says exactly what will be written.
struct TerminalHooksRow: View {
    let controller: TerminalHookController

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 12) {
                Image(systemName: "terminal")
                    .font(.system(size: 16, weight: .medium))
                    .foregroundStyle(controller.isInstalled ? HostPalette.ink : HostPalette.muted)
                    .frame(width: 26, height: 26)

                VStack(alignment: .leading, spacing: 2) {
                    Text("Answer Claude Code from your phone")
                        .font(.subheadline.weight(.medium))
                    Text("When Claude Code asks permission in any terminal or editor on this Mac, your phone gets Allow and Deny buttons. Adds two hooks to Claude Code's settings.")
                        .hostCaption()
                }

                Spacer(minLength: 12)

                Toggle("", isOn: Binding(get: { controller.isInstalled }, set: apply))
                    .hostSwitch()
            }

            if let failure = controller.failure {
                Text(failure)
                    .hostCaption()
                    .padding(.leading, 38)
            }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 12)
    }

    private func apply(_ enabled: Bool) {
        if enabled {
            guard Self.personAgrees() else { return }
            controller.install()
        } else {
            controller.uninstall()
        }
    }

    private static func personAgrees() -> Bool {
        let alert = NSAlert()
        alert.messageText = String(localized: "Let Peering answer Claude Code from your phone?")
        alert.informativeText = String(localized: """
            Peering will add a PermissionRequest hook and a Notification hook to ~/.claude/settings.json, and a small script next to the app's data.

            When Claude Code asks permission in any terminal or editor, your phone gets a notification with Allow and Deny. Nothing else in the file changes, and a copy of the original is kept as settings.json.peering-backup.

            Turn this off here at any time to take the hooks out again.
            """)
        alert.addButton(withTitle: String(localized: "Add Hooks"))
        alert.addButton(withTitle: String(localized: "Not Now"))
        return alert.runModal() == .alertFirstButtonReturn
    }
}
