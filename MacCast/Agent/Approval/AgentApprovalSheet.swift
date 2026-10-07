import MacCastKit
import RemoteCore
import SwiftUI

struct AgentApprovalSheet: View {
    let approval: AgentApproval
    let answer: (AgentApprovalDecision) -> Void

    private var call: AgentToolCall { approval.call }

    private var options: [AgentToolOption] { call.options ?? [] }

    @State private var height: CGFloat = 340

    var body: some View {
        // Measured inside a scroll view: measured in a plain stack the content was squeezed to the sheet's own height first, so a long question could never make the sheet taller and was cut off. The scroll view proposes no height, and still scrolls if the ask outgrows the screen.
        ScrollView {
        VStack(alignment: .leading, spacing: 16) {
            header
            if let detail = approval.reason ?? call.detail, !detail.isEmpty {
                Text(detail)
                    .font(.system(size: 13, design: .monospaced))
                    .foregroundStyle(.white.opacity(0.85))
                    .lineSpacing(2)
                    .padding(12)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(.white.opacity(0.06), in: RoundedRectangle(cornerRadius: 12, style: .continuous))
            }
            if options.isEmpty {
                HStack(spacing: 10) {
                    side("Deny", filled: false) { answer(.deny) }
                    side("Allow", filled: true) { answer(.allow) }
                }
            } else {
                VStack(spacing: 8) {
                    ForEach(Array(options.enumerated()), id: \.element.label) { _, option in
                        optionRow(option)
                    }
                }
            }
        }
        .padding(20)
        .onGeometryChange(for: CGFloat.self) { $0.size.height } action: { height = $0 }
        }
        .scrollBounceBehavior(.basedOnSize)
        // Measured rather than `.fitted`, which left a screen-tall sheet with the system's tint around the content.
        .presentationDetents([.height(height), .large])
        .presentationBackground(ColorPalette.backdrop)
    }

    private var header: some View {
        HStack(spacing: 10) {
            Image(systemName: options.isEmpty ? "hand.raised.fill" : "questionmark.bubble.fill")
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(.white.opacity(0.9))
                .frame(width: 30, height: 30)
                .background(.white.opacity(0.1), in: RoundedRectangle(cornerRadius: 9, style: .continuous))
            VStack(alignment: .leading, spacing: 1) {
                Text(verbatim: call.title)
                    .font(.system(size: 16, weight: .semibold))
                    .foregroundStyle(.white)
                    .lineLimit(1)
                Text(options.isEmpty ? "Wants to run on your Mac" : "Asks a question")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Spacer(minLength: 4)
        }
    }

    private func side(_ label: String, filled: Bool, run: @escaping () -> Void) -> some View {
        Button(action: run) {
            Text(label)
                .font(.system(size: 15, weight: .semibold))
                .foregroundStyle(filled ? ColorPalette.onInk : .white)
                .frame(maxWidth: .infinity)
                .frame(height: 46)
                .background {
                    if filled {
                        RoundedRectangle(cornerRadius: 14, style: .continuous).fill(ColorPalette.ink)
                    } else {
                        RoundedRectangle(cornerRadius: 14, style: .continuous)
                            .strokeBorder(.white.opacity(0.22))
                    }
                }
                .contentShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
        }
        .buttonStyle(.plain)
    }

    private func optionRow(_ option: AgentToolOption) -> some View {
        Button {
            answer(.choose(option.label))
        } label: {
            HStack(alignment: .firstTextBaseline, spacing: 10) {
                VStack(alignment: .leading, spacing: 2) {
                    Text(option.label)
                        .font(.system(size: 15, weight: .medium))
                        .foregroundStyle(.white)
                    if let detail = option.detail, !detail.isEmpty {
                        Text(detail)
                            .font(.caption)
                            .foregroundStyle(.white.opacity(0.55))
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
                Spacer(minLength: 6)
                Image(systemName: "chevron.right")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.tertiary)
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 10)
            .contentShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .strokeBorder(.white.opacity(0.22))
            )
        }
        .buttonStyle(.plain)
    }
}
