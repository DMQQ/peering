import MacCastKit
import RemoteCore
import SwiftUI

/// No red and green: the +/- prefix carries the meaning, as everywhere in the palette.
struct AgentDiffBlock: View {
    private let reading: AgentDiffLines

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
            if reading.added > 0 {
                Text("+\(reading.added)")
                    .font(.system(size: 11, weight: .semibold, design: .monospaced))
                    .foregroundStyle(.white.opacity(0.85))
            }
            if reading.removed > 0 {
                Text("-\(reading.removed)")
                    .font(.system(size: 11, weight: .semibold, design: .monospaced))
                    .foregroundStyle(.white.opacity(0.45))
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 9)
    }

    private func row(_ line: AgentDiffLines.Line) -> some View {
        HStack(alignment: .top, spacing: 8) {
            Text(marker(line.kind))
                .font(.system(size: 12, weight: .semibold, design: .monospaced))
                .foregroundStyle(line.kind == .context ? .white.opacity(0.3) : .white.opacity(0.75))
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
        .background(line.kind == .added ? Color.white.opacity(0.06) : .clear)
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
        case .removed: return .white.opacity(0.45)
        case .context: return .white.opacity(0.7)
        }
    }
}
