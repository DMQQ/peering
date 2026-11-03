import PeeringKit
import SwiftUI

/// A Markdown table, outlined and not filled, scrolling sideways when its columns are wider than the chat.
struct AgentMarkdownTableView: View {
    let table: AgentMarkdown.Table

    var body: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            Grid(alignment: .topLeading, horizontalSpacing: 0, verticalSpacing: 0) {
                row(table.header, isHeader: true)
                ForEach(Array(table.rows.enumerated()), id: \.offset) { _, cells in
                    Divider().overlay(.white.opacity(0.08))
                    row(cells, isHeader: false)
                }
            }
            .overlay { RoundedRectangle(cornerRadius: 10, style: .continuous).strokeBorder(.white.opacity(0.1)) }
            .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
        }
        .scrollBounceBehavior(.basedOnSize)
    }

    private func row(_ cells: [String], isHeader: Bool) -> some View {
        GridRow {
            ForEach(Array(cells.enumerated()), id: \.offset) { column, cell in
                let alignment = table.alignments[column]
                AgentMarkdownText.inline(cell)
                    .font(.system(size: 14, weight: isHeader ? .semibold : .regular))
                    .foregroundStyle(.white.opacity(isHeader ? 1 : 0.9))
                    .multilineTextAlignment(textAlignment(alignment))
                    .frame(minWidth: 56, maxWidth: 260, alignment: frameAlignment(alignment))
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.horizontal, 10)
                    .padding(.vertical, 7)
                    .textSelection(.enabled)
            }
        }
    }

    private func textAlignment(_ alignment: AgentMarkdown.Table.Alignment) -> TextAlignment {
        switch alignment {
        case .leading: .leading
        case .center: .center
        case .trailing: .trailing
        }
    }

    private func frameAlignment(_ alignment: AgentMarkdown.Table.Alignment) -> Alignment {
        switch alignment {
        case .leading: .leading
        case .center: .center
        case .trailing: .trailing
        }
    }
}
