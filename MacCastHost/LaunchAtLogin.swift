import ServiceManagement
import SwiftUI

/// Whether the host opens itself when this Mac is logged into.
///
/// This is the other half of "connect from anywhere". A relay session needs the host app running,
/// so a Mac that has been restarted is a Mac that cannot be reached until somebody notices and
/// opens it — which is not a thing anyone discovers at a good moment. They discover it on a train,
/// in another country, looking at a phone that says the Mac is offline.
///
/// `SMAppService.mainApp` rather than a separate login-item helper bundle: the app is the thing
/// that has to run, and a helper would be a second binary to sign, notarise and keep in step for
/// no gain. Registration is owned by the system rather than by us, so there is no preference of
/// ours to drift out of step with it — `status` is the truth, and this reads it.
enum LaunchAtLogin {
    /// Whether the app will open at login, as the system sees it.
    static var isEnabled: Bool { SMAppService.mainApp.status == .enabled }

    /// Whether the registration is waiting for the user to allow it.
    ///
    /// macOS can put a registration into `.requiresApproval`: the app asked, and the system wants
    /// the user to confirm it in Login Items. Nothing the app does afterwards changes that, so the
    /// row says where to go instead of leaving a switch that appears to do nothing.
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
                // The common cause is the app not living somewhere the system will register it
                // from, which in practice means it is being run from a build directory rather
                // than from /Applications.
                return String(localized: "Could not \(what) (\(underlying.localizedDescription)). If you are running the app from outside your Applications folder, move it there and try again.")
            }
        }
    }
}

/// One row of the settings pane, and its own state, because the system is the thing that decides.
///
/// A `Toggle` bound straight to `LaunchAtLogin.isEnabled` would lie: pressing it when approval is
/// pending leaves the switch on while the app still will not open at login. So the row reads the
/// status back after every attempt and says what happened when it is not what was asked for.
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
                        .font(.caption)
                        .foregroundStyle(HostPalette.muted)
                        .fixedSize(horizontal: false, vertical: true)
                }

                Spacer(minLength: 12)

                Toggle("", isOn: Binding(get: { isEnabled }, set: apply))
                    .labelsHidden()
                    .toggleStyle(.switch)
                    .controlSize(.small)
                    .tint(HostPalette.accent)
            }

            if needsApproval {
                Text("Waiting for permission. Allow Peering in System Settings → General → Login Items.")
                    .font(.caption)
                    .foregroundStyle(HostPalette.muted)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.leading, 38)
            } else if let failure {
                Text(failure)
                    .font(.caption)
                    .foregroundStyle(HostPalette.danger)
                    .fixedSize(horizontal: false, vertical: true)
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
            failure = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
        }
        // Read back rather than assume: the answer that matters is the system's, and it may differ
        // from what was asked for.
        isEnabled = LaunchAtLogin.isEnabled
        needsApproval = LaunchAtLogin.needsApproval
    }
}
