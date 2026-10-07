import ServiceManagement
import SwiftUI

/// Whether the host opens itself when this Mac is logged into.
enum LaunchAtLogin {
    static var isEnabled: Bool { SMAppService.mainApp.status == .enabled }

    static var needsApproval: Bool { SMAppService.mainApp.status == .requiresApproval }

    static func set(_ enabled: Bool) throws {
        do {
            if enabled {
                try SMAppService.mainApp.register()
            } else {
                try SMAppService.mainApp.unregister()
            }
        } catch {
            throw Failure.setting(enabled: enabled, underlying: error)
        }
    }

    enum Failure: LocalizedError {
        case setting(enabled: Bool, underlying: any Error)

        var errorDescription: String? {
            switch self {
            case .setting(let enabled, let underlying):
                let what = enabled ? String(localized: "add Peering to your login items") : String(localized: "remove it")
                return String(localized: "Could not \(what) (\(underlying.localizedDescription)). If you are running the app from outside your Applications folder, move it there and try again.")
            }
        }
    }
}

/// One row of the settings pane, and its own state, because the system is the thing that decides.
struct LaunchAtLoginRow: View {
    @State private var isEnabled = LaunchAtLogin.isEnabled
    @State private var needsApproval = LaunchAtLogin.needsApproval
    @State private var failure: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 12) {
                Image(systemName: "power")
                    .font(.system(size: 16, weight: .medium))
                    .foregroundStyle(isEnabled ? HostPalette.ink : HostPalette.muted)
                    .frame(width: 26, height: 26)

                VStack(alignment: .leading, spacing: 2) {
                    Text("Open at login")
                        .font(.subheadline.weight(.medium))
                    Text("Starts Peering for Mac when you log in, so this Mac can be reached without being woken by hand.")
                        .hostCaption()
                }

                Spacer(minLength: 12)

                Toggle("", isOn: Binding(get: { isEnabled }, set: apply))
                    .hostSwitch()
            }

            if needsApproval {
                Text("Waiting for permission. Allow Peering in System Settings → General → Login Items.")
                    .hostCaption()
                    .padding(.leading, 38)
            } else if let failure {
                Text(failure)
                    .hostCaption(HostPalette.danger)
                    .padding(.leading, 38)
            }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 12)
    }

    private func apply(_ wanted: Bool) {
        failure = nil
        do {
            try LaunchAtLogin.set(wanted)
        } catch {
            Analytics.failed(error, in: .launchAtLogin)
            failure = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
        }
        isEnabled = LaunchAtLogin.isEnabled
        needsApproval = LaunchAtLogin.needsApproval
    }
}
