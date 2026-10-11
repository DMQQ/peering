import SwiftUI

/// Before a page is open: the servers answering on the Mac, one tap each, or an address typed above.
struct AgentPreviewStart: View {
    let detected: [UInt16]
    let isProbing: Bool
    let notice: String?
    let open: (UInt16) -> Void
    let lookAgain: () -> Void

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 22) {
                PreviewEmptyState(
                    symbol: "safari",
                    title: String(localized: "Open a server running on your Mac"),
                    detail: String(localized: "Type a port, or pick one that is answering now. Only localhost and 127.0.0.1 on the Mac can be opened.")
                ) {}
                .padding(.top, 28)
                servers
                if let notice {
                    Text(verbatim: notice)
                        .font(.footnote)
                        .foregroundStyle(ColorPalette.caution)
                }
                Text("Live reload over WebSocket is not carried here. Reload to see changes.")
                    .font(.caption)
                    .foregroundStyle(.tertiary)
                    .frame(maxWidth: .infinity)
                    .multilineTextAlignment(.center)
            }
            .padding(.horizontal, 16)
            .padding(.bottom, 28)
        }
        .scrollBounceBehavior(.basedOnSize)
    }

    private var servers: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 8) {
                Text(detected.isEmpty && !isProbing ? "Nothing found on the usual ports" : "On the Mac now")
                    .font(.caption.weight(.medium))
                    .foregroundStyle(.secondary)
                if isProbing { ProgressView().controlSize(.mini) }
                Spacer()
                Button("Look again", action: lookAgain)
                    .font(.caption.weight(.medium))
                    .disabled(isProbing)
            }
            .padding(.horizontal, 4)
            if !detected.isEmpty {
                VStack(spacing: 0) {
                    ForEach(Array(detected.enumerated()), id: \.element) { index, port in
                        if index > 0 { Controls.divider }
                        row(port)
                    }
                }
                .overlay(RoundedRectangle(cornerRadius: 16, style: .continuous).strokeBorder(.white.opacity(0.14)))
            }
        }
    }

    private func row(_ port: UInt16) -> some View {
        Button { open(port) } label: {
            HStack(spacing: 12) {
                Text(verbatim: ":\(String(port))")
                    .font(.system(size: 17, weight: .semibold, design: .monospaced))
                    .foregroundStyle(ColorPalette.ink)
                Text(verbatim: "localhost:\(String(port))")
                    .font(.system(size: 13, design: .monospaced))
                    .foregroundStyle(.secondary)
                Spacer(minLength: 6)
                Image(systemName: "chevron.right")
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(.white.opacity(0.35))
            }
            .padding(.horizontal, 16)
            .frame(height: 54)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }
}
