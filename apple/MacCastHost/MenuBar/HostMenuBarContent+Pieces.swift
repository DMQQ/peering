import AppKit
import MacCastKit
import RemoteCore
import SwiftUI

extension HostMenuBarContent {
    var footer: some View {
        HStack(spacing: 8) {
            Button { openMainWindow() } label: {
                Text(model.permissions.allRequiredGranted ? "Open Peering" : "Finish Setup")
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(Color.primary)
                    .frame(maxWidth: .infinity)
                    .frame(height: 30)
                    .background(Color.primary.opacity(0.08), in: RoundedRectangle(cornerRadius: HostPalette.controlRadius, style: .continuous))
                    .overlay(
                        RoundedRectangle(cornerRadius: HostPalette.controlRadius, style: .continuous)
                            .strokeBorder(Color.primary.opacity(0.12))
                    )
                    .contentShape(Rectangle())
            }
            .buttonStyle(PressableStyle())

            iconButton("exclamationmark.bubble", help: String(localized: "Report an issue")) {
                dismissMenuBar()
                NSWorkspace.shared.open(HostStatusView.reportURL)
            }
            iconButton("power.circle", help: String(localized: "Quit Peering")) {
                model.stop()
                NSApp.terminate(nil)
            }
            .keyboardShortcut("q")
        }
    }

    func card<Content: View>(title: String? = nil, @ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            if let title {
                Text(title)
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(Color.secondary.opacity(0.75))
            }
            content()
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .overlay(
            RoundedRectangle(cornerRadius: HostPalette.controlRadius + 2, style: .continuous)
                .strokeBorder(Color.primary.opacity(0.12))
        )
    }

    func switchRow(_ title: String, symbol: String, isOn: Binding<Bool>, note: String?) -> some View {
        HStack(alignment: .top, spacing: 9) {
            rowIcon(symbol, lit: isOn.wrappedValue)
            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .font(.system(size: 12))
                    .foregroundStyle(Color.primary)
                if let note {
                    Text(note)
                        .font(.caption2)
                        .foregroundStyle(Color.orange)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            .padding(.top, 5)
            Spacer(minLength: 0)
            Toggle("", isOn: isOn)
                .labelsHidden()
                .toggleStyle(.switch)
                .controlSize(.mini)
                .padding(.top, 4)
        }
    }

    func rowIcon(_ symbol: String, lit: Bool = false) -> some View {
        Image(systemName: symbol)
            .font(.system(size: 11, weight: .semibold))
            .foregroundStyle(lit ? Color.white : Color.secondary)
            .frame(width: 26, height: 26)
            .background(lit ? AnyShapeStyle(Color.accentColor.opacity(0.85)) : AnyShapeStyle(Color.primary.opacity(0.08)), in: Circle())
            .animation(HostMotion.state, value: lit)
    }

    private func iconButton(_ symbol: String, help: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.system(size: 13, weight: .medium))
                .foregroundStyle(Color.secondary)
                .frame(width: 30, height: 30)
                .overlay(
                    RoundedRectangle(cornerRadius: HostPalette.controlRadius, style: .continuous)
                        .strokeBorder(Color.primary.opacity(0.12))
                )
                .contentShape(Rectangle())
        }
        .buttonStyle(PressableStyle())
        .help(help)
        .accessibilityLabel(help)
    }

    func openMainWindow() {
        dismissMenuBar()
        MainWindowOpener.show()
    }
}
