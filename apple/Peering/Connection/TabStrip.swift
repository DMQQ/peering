import PeeringKit
import SwiftUI

/// A horizontal strip of names shared by the session strip and both terminal screens, so the tab looks and scrolls the same on all three.
/// The accessory is outside the scroller on purpose: pinned, it stays in the same place however long the row gets.
struct TabStrip<Item: Identifiable, Tab: View, Accessory: View>: View {
    let items: [Item]
    let selection: Item.ID?

    /// What is drawn behind the row. The session strip floats over the picture and asks for frosted glass, hence a ``ShapeStyle`` (a material) and not a `Color`.
    var fill: AnyShapeStyle = AnyShapeStyle(Color.clear)

    @ViewBuilder let tab: (Item, _ isSelected: Bool) -> Tab

    @ViewBuilder let accessory: () -> Accessory

    var body: some View {
        HStack(alignment: .top, spacing: 0) {
            ScrollViewReader { reader in
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 2) {
                        ForEach(items) { item in
                            tab(item, item.id == selection).id(item.id)
                        }
                    }
                    .padding(.leading, 8)
                    .padding(.trailing, 4)
                    .padding(.top, 8)
                }
                .onChange(of: selection) { _, id in
                    guard let id else { return }
                    withAnimation(Motion.settle) { reader.scrollTo(id, anchor: .center) }
                }
            }

            accessory()
        }
        // Behind the tabs, not among them: inside the scrolled stack the seam slid along with the tabs.
        // One layer holding both, because a second `.background` goes behind the first.
        .background {
            ZStack(alignment: .bottom) {
                Rectangle().fill(fill)
                hairline
            }
        }
    }

    private var hairline: some View {
        Rectangle()
            .fill(Color.white.opacity(0.08))
            .frame(height: 1)
    }
}

/// One tab, separate from ``TabStrip`` so call sites can hang renames and menus on it.
struct TabChip<Mark: View, Name: View>: View {
    let isSelected: Bool
    let onSelect: () -> Void

    /// `nil` draws no cross at all, not a greyed or hidden one.
    let onClose: (() -> Void)?
    let closeLabel: String

    @ViewBuilder var mark: () -> Mark
    @ViewBuilder var name: () -> Name

    /// Fixed so names do not shuffle as a `ProgressView`, `xmark` and letter change width.
    private static var markWidth: CGFloat { 14 }

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 7) {
                mark()
                    .frame(width: Self.markWidth)

                name()

                if let onClose {
                    Button(action: onClose) {
                        Image(systemName: "xmark")
                            .font(.system(size: 9, weight: .bold))
                            .foregroundStyle(.secondary)
                            .frame(width: 22, height: 32)
                            .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel(closeLabel)
                }
            }
            .padding(.horizontal, 10)
            // One height for every tab: a taller selected tab read as a lump.
            .frame(height: 32)
            // Capped because a name can be a long command.
            .frame(minWidth: 88, maxWidth: 190, alignment: .leading)

            // Ink, not the accent: blue means something here wants you (a lock, a question, a failure).
            Capsule()
                .fill(isSelected ? ColorPalette.ink : Color.clear)
                .frame(height: 2)
                .padding(.horizontal, 9)
                .padding(.bottom, 5)
        }
        .contentShape(Rectangle())
        .onTapGesture(perform: onSelect)
    }
}

/// Monospaced because most names are commands; one font keeps all three strips the same width and height.
struct TabName: View {
    let text: String
    let isSelected: Bool
    let colour: Color

    var body: some View {
        Text(text)
            .font(.system(size: 12.5, weight: isSelected ? .semibold : .regular, design: .monospaced))
            .foregroundStyle(colour)
            .lineLimit(1)
            .truncationMode(.tail)
    }
}
