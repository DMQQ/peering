import PeeringKit
import RemoteCore
import SwiftUI

/// Added and removed lines are tinted green and red; the +/- prefix still carries the meaning without colour.
struct AgentDiffBlock: View {
    private let reading: AgentDiffLines
    @Environment(\.colorSchemeContrast) private var contrast
    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency

    init(diff: String) {
        reading = AgentDiffLines(diff)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header
            Rectangle().fill(.white.opacity(0.07)).frame(height: 1)
            VStack(alignment: .leading, spacing: 0) {
                ForEach(Array(reading.lines.enumerated()), id: \.offset) { _, line in
                    row(line)
                }
            }
            .padding(.vertical, 5)
        }
        .background {
            RoundedRectangle(cornerRadius: 12, style: .continuous).fill(.white.opacity(0.05))
        }
        .overlay {
            RoundedRectangle(cornerRadius: 12, style: .continuous).strokeBorder(.white.opacity(0.08))
        }
    }

    private var header: some View {
        HStack(spacing: 8) {
            Image(systemName: "doc.text")
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(.white.opacity(0.55))
            Text(reading.path ?? String(localized: "Changes"))
                .font(.system(size: 12, design: .monospaced))
                .foregroundStyle(.white.opacity(0.8))
                .lineLimit(1)
                .truncationMode(.middle)
            Spacer(minLength: 8)
            DiffCounts(added: reading.added, removed: reading.removed)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 9)
    }

    private func row(_ line: AgentDiffLines.Line) -> some View {
        HStack(alignment: .top, spacing: 8) {
            Text(marker(line.kind))
                .font(.system(size: 12, weight: .semibold, design: .monospaced))
                .foregroundStyle(tone(line.kind).accent ?? .white.opacity(0.3))
                .frame(width: 9, alignment: .leading)
            Text(line.text)
                .font(.system(size: 12, design: .monospaced))
                .foregroundStyle(textColour(line.kind))
                .textSelection(.enabled)
                .fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 1.5)
        .background(tone(line.kind).tint(emphasised: contrast == .increased || reduceTransparency))
    }

    private func tone(_ kind: AgentDiffLines.Kind) -> DiffTone {
        switch kind {
        case .added: .added
        case .removed: .removed
        case .context: .neutral
        }
    }

    private func marker(_ kind: AgentDiffLines.Kind) -> String {
        switch kind {
        case .added: return "+"
        case .removed: return "-"
        case .context: return " "
        }
    }

    private func textColour(_ kind: AgentDiffLines.Kind) -> Color {
        switch kind {
        case .added: return .white.opacity(0.95)
        case .removed: return .white.opacity(0.8)
        case .context: return .white.opacity(0.7)
        }
    }
}
