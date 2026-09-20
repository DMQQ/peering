import MacCastKit
import SwiftUI

/// A horizontal strip of names, one per thing that can be selected.
///
/// **One drawing for three surfaces, and the reason is drift rather than tidiness.** The session
/// strip, the Mac terminals and the SSH terminals were three strips that had stopped agreeing
/// about anything: the tab was a different height in each, one put a rule under its selection while
/// the others wore a fill, and only one of the three scrolled its selection into view. Somebody who
/// had learned what a tab looks like on one of the screens had learned nothing about the other two,
/// and every change to one was a change the other two never got.
///
/// What is shared is the whole of the tab: the mark slot, the name, the cross, the rule under the
/// selected one, the metrics, the hairline the row stands on, and the rule that a selection is
/// scrolled to the middle of the strip when it changes. What a surface supplies is what is
/// genuinely its own — the mark a tab carries, the colour its name is written in, whether its tabs
/// can be closed at all, and the one control pinned past the end of the row.
///
/// **The accessory is outside the scroller on purpose.** A control that slides away as items are
/// opened is a control that has to be hunted for, and both of the accessories here are things the
/// user reaches for rather than reads: the switch between a terminal and its folders, and the `+`
/// that opens another Mac. Pinned, they are in the same place however long the row gets.
struct TabStrip<Item: Identifiable, Tab: View, Accessory: View>: View {
    let items: [Item]
    let selection: Item.ID?

    /// What is drawn behind the whole row, under the seam.
    ///
    /// Clear for the two strips that sit on a panel that is already black. The session strip
    /// floats over the picture instead, where the names are ink on whatever the Mac happens to be
    /// showing, and ink over a bright document is a row that cannot be read at all — so it asks
    /// for the same frosted glass the status pill above it is made of, and the two read as one
    /// piece of chrome rather than a band with a capsule on top of it.
    ///
    /// A ``ShapeStyle`` rather than a `Color` because the answer is a material, and a material is
    /// not a colour.
    var fill: AnyShapeStyle = AnyShapeStyle(Color.clear)

    /// One tab. Call sites build a ``TabChip`` here, and are free to hang their own gestures and
    /// menus on it — which is why the strip does not carry them.
    @ViewBuilder let tab: (Item, _ isSelected: Bool) -> Tab

    /// The control pinned past the end of the row. `EmptyView` for a strip that has none.
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
                // A new item arrives at the far end of the strip, and one that wants you is
                // somewhere you were not looking. Both are worth being shown rather than hunted
                // for, and both are things this selection is what changes.
                .onChange(of: selection) { _, id in
                    guard let id else { return }
                    withAnimation(Motion.settle) { reader.scrollTo(id, anchor: .center) }
                }
            }

            accessory()
        }
        // The seam the row stands on, across the whole panel and behind the tabs rather than among
        // them: drawn inside the scrolled stack it was only as wide as the tabs were and slid along
        // with them, which is a rule drawn on the tabs and not the edge under them.
        //
        // One layer holding both, because a second `.background` goes *behind* the first rather
        // than over it — the seam has to sit on top of the fill, not underneath it.
        .background {
            ZStack(alignment: .bottom) {
                Rectangle().fill(fill)
                hairline
            }
        }
    }

    /// The line between one band of a panel and the next.
    ///
    /// One line and one weight everywhere, because these are one object cut into strips. A seam a
    /// point heavier in one place than another is the kind of thing that reads as sloppy without
    /// anyone being able to say why.
    private var hairline: some View {
        Rectangle()
            .fill(Color.white.opacity(0.08))
            .frame(height: 1)
    }
}

/// One tab: a mark, a name, and the cross that closes it.
///
/// Separate from ``TabStrip`` rather than a closure inside it, because two of the three surfaces
/// put things on a tab that the strip has no business knowing about — a field in the name's place
/// while it is being renamed, a menu on a long press — and a chip that a call site can hang its own
/// modifiers on is what keeps those out of the strip's generics.
struct TabChip<Mark: View, Name: View>: View {
    let isSelected: Bool
    let onSelect: () -> Void

    /// `nil` for a strip whose tabs cannot be closed, which draws no cross at all.
    ///
    /// **Not a greyed cross or a hidden one.** A control that is drawn but does nothing is a
    /// control that answers "what does this do" with nothing, and on the session strip the question
    /// is answered properly instead: a Mac is ended from its own tab, by a cross that is really
    /// there. See ``SessionTabs``.
    let onClose: (() -> Void)?
    let closeLabel: String

    @ViewBuilder var mark: () -> Mark
    @ViewBuilder var name: () -> Name

    /// The mark slot's width, fixed so the names do not shuffle.
    ///
    /// A `ProgressView`, an `xmark` and a letter each take a different width, so a row of tabs
    /// whose marks are whatever those happen to be is a row of names starting at different places
    /// and moving sideways as states come and go. Wide enough for the widest mark any strip draws,
    /// and one number rather than three, because the three strips are the same object.
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
            // One height for every tab. The tab in front used to be the taller one, and that is
            // what made a strip read as three-dimensional: whatever grows upward out of its own
            // row is a lump in it. What says which one is on is ink and the rule beneath it.
            .frame(height: 32)
            // Capped, because a name is a command or a Mac and both can be long. The field a tab
            // shows while it is being renamed is narrower than the cap by some way, so it is not
            // the case that has to be uncapped for.
            .frame(minWidth: 88, maxWidth: 190, alignment: .leading)

            // The rule, under the tab rather than around it, and clear of its ends so it reads as
            // sitting on the seam rather than as the tab being boxed in. Ink rather than the
            // accent: blue is this app's "something here wants you" — a lock, a question, a
            // failure — and a tab would wear the same blue for two different reasons.
            Capsule()
                .fill(isSelected ? ColorPalette.ink : Color.clear)
                .frame(height: 2)
                .padding(.horizontal, 9)
                .padding(.bottom, 5)
        }
        .contentShape(Rectangle())
        // The tab answers a tap by becoming the selection. Renaming, menus and the rest are the
        // call site's, hung on this chip from outside.
        .onTapGesture(perform: onSelect)
    }
}

/// A tab's name, drawn the one way every strip draws it.
///
/// Monospaced, because most names on a strip are commands and a command is read by shape. A Mac's
/// name is not a command, and reading "Damian's MacBook Pro" in a monospaced face is a small lie
/// about what it is — but it is a smaller one than three strips whose tabs are different widths
/// and whose names sit at different heights, which is what having a font per surface cost.
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
