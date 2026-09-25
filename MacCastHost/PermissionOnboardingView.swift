import AppKit
import SwiftUI

/// Mandatory first-run setup for the two permissions that make the host functional.
///
/// This is deliberately the product root rather than a sheet or a dismissible tour. macOS can
/// refuse either grant, but Peering must not pretend it can host while capture or input is absent.
struct PermissionOnboardingView: View {
    @Environment(HostModel.self) private var model

    private var permissions: Permissions { model.permissions }

    var body: some View {
        ZStack {
            HostPalette.backdrop.ignoresSafeArea()
            HostPalette.stageLight.ignoresSafeArea()

            ScrollView {
                VStack(spacing: 30) {
                    header

                    VStack(spacing: 12) {
                        permissionStep(
                            number: 1,
                            title: "Accessibility",
                            detail: "Peering uses this to turn gestures and keys from your iPhone into input on this Mac.",
                            consequence: "Without it, you can see the Mac but cannot control it.",
                            symbol: "cursorarrow.click.2",
                            granted: permissions.accessibilityGranted,
                            allow: {
                                permissions.requestAccessibility()
                                permissions.openAccessibilitySettings()
                            },
                        )

                        permissionStep(
                            number: 2,
                            title: "Screen Recording",
                            detail: "Peering uses this to send a live picture of this Mac to your iPhone.",
                            consequence: "Without it, your iPhone connects to a black screen.",
                            symbol: "rectangle.dashed.badge.record",
                            granted: permissions.screenRecordingGranted,
                            allow: {
                                permissions.requestScreenRecording()
                                Task { @MainActor in
                                    // Give ScreenCaptureKit a moment to register Peering before
                                    // revealing its row in System Settings.
                                    try? await Task.sleep(for: .milliseconds(350))
                                    permissions.openScreenRecordingSettings()
                                }
                            },
                        )
                    }

                    footer
                }
                .frame(maxWidth: 680)
                .padding(.horizontal, 36)
                .padding(.vertical, 44)
                .frame(maxWidth: .infinity)
            }
        }
        .frame(minWidth: 720, idealWidth: 900, minHeight: 560, idealHeight: 680)
        // The Accessibility checkbox takes effect immediately. Poll only that inexpensive API;
        // probing ScreenCaptureKit repeatedly can raise another system permission interaction.
        .task {
            while !Task.isCancelled, !permissions.accessibilityGranted {
                permissions.refreshAccessibility()
                try? await Task.sleep(for: .seconds(1))
            }
        }
    }

    private var header: some View {
        VStack(spacing: 16) {
            Image(nsImage: NSApplication.shared.applicationIconImage)
                .resizable()
                .frame(width: 76, height: 76)
                .shadow(color: .black.opacity(0.42), radius: 18, y: 9)
                .accessibilityHidden(true)

            VStack(spacing: 8) {
                Text("Let Peering access this Mac")
                    .font(HostDisplayFont.display(34))
                    .tracking(-1)
                    .multilineTextAlignment(.center)

                Text("Both permissions are required. Without them, Peering cannot show or control this Mac.")
                    .font(.system(size: 15))
                    .foregroundStyle(HostPalette.muted)
                    .multilineTextAlignment(.center)
                    .frame(maxWidth: 520)
            }
        }
    }

    private func permissionStep(
        number: Int,
        title: String,
        detail: String,
        consequence: String,
        symbol: String,
        granted: Bool,
        allow: @escaping () -> Void
    ) -> some View {
        HStack(spacing: 16) {
            ZStack {
                RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .fill(granted ? HostPalette.success.opacity(0.16) : HostPalette.raised)
                Image(systemName: granted ? "checkmark" : symbol)
                    .font(.system(size: 18, weight: .semibold))
                    .foregroundStyle(granted ? HostPalette.success : HostPalette.ink)
            }
            .frame(width: 46, height: 46)

            VStack(alignment: .leading, spacing: 4) {
                HStack(spacing: 7) {
                    Text("\(number). \(title)")
                        .font(.system(size: 15, weight: .semibold))
                    Text(granted ? "Allowed" : "Required")
                        .font(.caption2.weight(.semibold))
                        .foregroundStyle(granted ? HostPalette.success : HostPalette.caution)
                        .padding(.horizontal, 7)
                        .padding(.vertical, 3)
                        .background(
                            (granted ? HostPalette.success : HostPalette.caution).opacity(0.12),
                            in: Capsule()
                        )
                }

                Text(detail)
                    .font(.caption)
                    .foregroundStyle(HostPalette.muted)
                    .fixedSize(horizontal: false, vertical: true)

                Text(consequence)
                    .font(.caption.weight(.medium))
                    .foregroundStyle(HostPalette.ink.opacity(0.82))
                    .fixedSize(horizontal: false, vertical: true)
            }

            Spacer(minLength: 16)

            if !granted {
                Button("Allow", action: allow)
                    .controlSize(.regular)
                    .buttonStyle(.borderedProminent)
                    .buttonBorderShape(.capsule)
            }
        }
        .padding(18)
        .hostPanel()
        .accessibilityElement(children: .contain)
    }

    @ViewBuilder
    private var footer: some View {
        if !permissions.screenRecordingGranted {
            VStack(spacing: 9) {
                Button("Relaunch Peering") { permissions.relaunch() }
                    .buttonStyle(.borderedProminent)
                    .controlSize(.large)

                Text("After allowing Screen Recording in System Settings, relaunch Peering to apply it.")
                    .font(.caption)
                    .foregroundStyle(HostPalette.faint)
                    .multilineTextAlignment(.center)
            }
        } else if !permissions.accessibilityGranted {
            VStack(spacing: 9) {
                Button("Check Accessibility") { permissions.refreshAccessibility() }
                    .controlSize(.large)
                Text("Peering will continue automatically as soon as both permissions are allowed.")
                    .font(.caption)
                    .foregroundStyle(HostPalette.faint)
            }
        }
    }
}

#Preview {
    PermissionOnboardingView()
        .environment(HostModel())
}
