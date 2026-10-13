import SwiftUI

/// The face of a file or folder row, shared by the file browser and the Changes tree. It draws no button: the caller wraps it, since each screen decides what a tap does.
struct FileEntryRow<Trailing: View>: View {
    enum Chevron {
        case none
        /// Opens the folder as a page.
        case right
        /// An expandable folder that is open.
        case down
    }

    let symbol: String
    let name: String
    var secondary: Text?
    var indent = 0
    var chevron = Chevron.none
    var isDimmed = false
    var leadingInset: CGFloat = 16
    var trailingInset: CGFloat = 16
    @ViewBuilder var trailing: () -> Trailing

    var body: some View {
        HStack(spacing: 11) {
            Controls.icon(symbol)

            VStack(alignment: .leading, spacing: 2) {
                Text(name)
                    .font(.subheadline.weight(.medium))
                    .foregroundStyle(ColorPalette.ink)
                    .lineLimit(1)
                    .truncationMode(.middle)
                // One line only: a wrapping second line gives rows of two heights.
                if let secondary {
                    secondary
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
            }

            Spacer(minLength: 10)

            trailing()

            if chevron != .none {
                Image(systemName: chevron == .down ? "chevron.down" : "chevron.right")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.tertiary)
            }
        }
        .opacity(isDimmed ? 0.45 : 1)
        .padding(.leading, leadingInset + CGFloat(indent) * 16)
        .padding(.trailing, trailingInset)
        .padding(.vertical, 8)
        .contentShape(Rectangle())
    }
}

extension FileEntryRow where Trailing == EmptyView {
    init(
        symbol: String,
        name: String,
        secondary: Text? = nil,
        indent: Int = 0,
        chevron: Chevron = .none,
        isDimmed: Bool = false,
        leadingInset: CGFloat = 16,
        trailingInset: CGFloat = 16
    ) {
        self.init(
            symbol: symbol, name: name, secondary: secondary, indent: indent, chevron: chevron,
            isDimmed: isDimmed, leadingInset: leadingInset, trailingInset: trailingInset
        ) { EmptyView() }
    }
}
