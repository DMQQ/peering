import PeeringKit
import RemoteCore
import SwiftUI

struct AgentApprovalSheet: View {
    let approval: AgentApproval
    let answer: (AgentApprovalDecision) -> Void

    private var call: AgentToolCall { approval.call }

    private var questions: [AgentQuestion] { call.questions ?? [] }

    private var current: AgentQuestion? { questions.indices.contains(step) ? questions[step] : nil }

    private var options: [AgentToolOption] { current?.options ?? [] }

    @State private var height: CGFloat = 340
    @State private var step = 0
    @State private var picked: [String] = []

    var body: some View {
        // Measured inside a scroll view: measured in a plain stack the content was squeezed to the sheet's own height first, so a long question could never make the sheet taller and was cut off. The scroll view proposes no height, and still scrolls if the ask outgrows the screen.
        ScrollView {
        VStack(alignment: .leading, spacing: 16) {
            header
            if let detail = current?.question ?? call.detail ?? approval.reason, !detail.isEmpty {
                Text(detail)
                    .font(.system(size: 13, design: .monospaced))
                    .foregroundStyle(.white.opacity(0.85))
                    .lineSpacing(2)
                    .padding(12)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(.white.opacity(0.06), in: RoundedRectangle(cornerRadius: 12, style: .continuous))
                    .accessibilityIdentifier("approval.command")
            }
            if let why = reasonUnderCommand {
                Text(why)
                    .font(.caption)
                    .foregroundStyle(.white.opacity(0.55))
                    .fixedSize(horizontal: false, vertical: true)
                    .accessibilityIdentifier("approval.reason")
            }
            if options.isEmpty {
                HStack(spacing: 10) {
                    side(String(localized: "Deny"), filled: false) { answer(.deny) }
                    side(String(localized: "Allow"), filled: true) { answer(.allow) }
                }
            } else {
                VStack(spacing: 8) {
                    ForEach(options, id: \.label) { option in
                        optionRow(option)
                    }
                    if step > 0 { backButton }
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
                Text(verbatim: current?.header ?? call.title)
                    .font(.system(size: 16, weight: .semibold))
                    .foregroundStyle(.white)
                    .lineLimit(1)
                Text(subtitle)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Spacer(minLength: 4)
        }
    }

    /// The CLI's reason for asking, shown only when the block above is the command and not the reason itself.
    private var reasonUnderCommand: String? {
        guard current == nil, call.detail?.isEmpty == false, let reason = approval.reason, !reason.isEmpty else { return nil }
        return reason
    }

    private var subtitle: LocalizedStringKey {
        if options.isEmpty { return "Wants to run on your Mac" }
        if questions.count > 1 { return "Question \(step + 1) of \(questions.count)" }
        return "Asks a question"
    }

    private var backButton: some View {
        Button {
            withAnimation(.snappy) {
                step -= 1
                picked.removeLast()
            }
        } label: {
            Text("Back")
                .font(.system(size: 14, weight: .medium))
                .foregroundStyle(.white.opacity(0.6))
                .frame(maxWidth: .infinity)
                .frame(height: 40)
        }
        .buttonStyle(.plain)
        .accessibilityIdentifier("approval.back")
    }

    private func choose(_ label: String) {
        let answers = picked + [label]
        if answers.count == questions.count {
            answer(.choose(answers))
        } else {
            withAnimation(.snappy) {
                picked = answers
                step += 1
            }
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
            choose(option.label)
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
                Image(systemName: step == questions.count - 1 ? "checkmark" : "chevron.right")
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
        .accessibilityIdentifier("approval.option.\(option.label)")
    }
}
