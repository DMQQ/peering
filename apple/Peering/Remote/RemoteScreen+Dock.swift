import RemoteCore
import SwiftUI
import UIKit

private extension Array {
    func chunked(into size: Int) -> [[Element]] {
        guard size > 0 else { return isEmpty ? [] : [self] }
        return stride(from: 0, to: count, by: size).map {
            Array(self[$0 ..< Swift.min($0 + size, count)])
        }
    }
}

extension View {
    func keyChip() -> some View {
        lineLimit(1)
            .minimumScaleFactor(0.6)
            .frame(maxWidth: .infinity, minHeight: 44)
            .glassSurface(in: RoundedRectangle(cornerRadius: 9, style: .continuous), interactive: true)
            .contentShape(RoundedRectangle(cornerRadius: 9, style: .continuous))
    }
}

extension RemoteScreen {
    var dockHeight: CGFloat {
        dockCardHeight + ChromeMetrics.dockDotsGap + ChromeMetrics.dockPageDotsHeight
    }

    var dockCardHeight: CGFloat {
        dockExpanded ? ChromeMetrics.dockExpandedHeight : ChromeMetrics.dockCollapsedHeight
    }

    var dockGridHeight: CGFloat {
        dockExpanded ? ChromeMetrics.dockExpandedGridHeight : ChromeMetrics.buttonHeight
    }

    func portraitDock(width: CGFloat) -> some View {
        VStack(spacing: ChromeMetrics.dockDotsGap) {
            HStack(spacing: 0) {
                // The sheets page and the chevron does not. Fixed at the trailing edge it
                // stays under the thumb that just pressed it, and it is reachable from any
                // sheet, which it was not while it was a cell of the first one: opening or
                // shutting the dock meant swiping back to that sheet first.
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 0) {
                        ForEach(dockSheets) { sheet in
                            dockSheetView(sheet, expanded: dockExpanded)
                                .containerRelativeFrame(.horizontal)
                                .id(sheet.id)
                        }
                    }
                    .scrollTargetLayout()
                }
                .scrollTargetBehavior(.paging)
                .scrollPosition(id: $dockPage)

                dockToggle
                    .frame(width: ChromeMetrics.dockToggleWidth)
            }
            .frame(height: dockGridHeight)
            .padding(.vertical, ChromeMetrics.railPadding)
            .padding(.horizontal, ChromeMetrics.railSidePadding)
            // The height as well as the width, and it is the bar's own number rather than a copy
            // of it: ``dockHeight`` is what the pointer above is placed from, and until this was
            // pinned it was also a number the bar could disagree with. A content-sized bar is
            // only as tall as its contents, and the moment any cell in it is flexible in height
            // the column hands the bar whatever it has going spare, which it did, over the
            // picture, for the whole of the joystick's room. Fixed, the two readings of "how
            // tall is the dock" cannot drift.
            .frame(width: width, height: dockCardHeight)
            .clipShape(dockShape)
            .glassSurface(in: dockShape)

            dockPageDots
        }
        .frame(width: width, height: dockHeight)
    }

    @ViewBuilder
    func dockRows<Item: Identifiable, Content: View>(
        _ items: [Item],
        expanded: Bool,
        @ViewBuilder item: @escaping (Item) -> Content
    ) -> some View {
        let columns = ChromeMetrics.dockColumns
        let rows = expanded ? ChromeMetrics.dockExpandedRows : 1
        VStack(spacing: ChromeMetrics.buttonGap) {
            ForEach(0..<rows, id: \.self) { row in
                HStack(spacing: 0) {
                    ForEach(0..<columns, id: \.self) { column in
                        let index = row * columns + column
                        if index < items.count {
                            item(items[index])
                        } else {
                            emptyDockSlot
                        }
                    }
                }
            }
        }
    }

    var dockSheets: [DockSheet] {
        let capacity = ChromeMetrics.dockColumns * (dockExpanded ? ChromeMetrics.dockExpandedRows : 1)
        let controls = DockControl.allCases.chunked(into: capacity).enumerated().map { index, chunk in
            DockSheet(id: "controls-\(index)", controls: chunk, edits: [])
        }
        let edits = quickActions.chunked(into: capacity).enumerated().map { index, chunk in
            DockSheet(id: "edits-\(index)", controls: [], edits: chunk)
        }
        // The app on screen gets the second place: the first sheet never moves, and what the app
        // offers is one swipe away rather than behind every other control.
        guard let profile = activeApplicationProfile, let first = controls.first else {
            return controls + edits
        }
        let actions = profile.actions.map { action in
            QuickAction(chord: action.title, label: action.label, accessibilityLabel: action.detail) {
                sendKey(keyCode: action.keyCode, modifiers: action.modifiers)
            }
        }
        let app = actions.chunked(into: capacity).enumerated().map { index, chunk in
            DockSheet(
                id: "app-\(profile.id)-\(index)",
                controls: [],
                edits: chunk,
                applicationName: profile.name
            )
        }
        return [first] + app + controls.dropFirst() + edits
    }

    @ViewBuilder
    func dockSheetView(_ sheet: DockSheet, expanded: Bool) -> some View {
        if sheet.edits.isEmpty {
            dockRows(sheet.controls, expanded: expanded) { dockControlView($0) }
        } else {
            dockRows(sheet.edits, expanded: expanded) { edit in
                ShortcutRailButton(
                    chord: edit.chord,
                    label: edit.label,
                    accessibilityLabel: edit.accessibilityLabel,
                    action: edit.action
                )
            }
        }
    }

    @ViewBuilder
    func dockControlView(_ control: DockControl) -> some View {
        switch control {
        case .mode: modeButton
        case .sources: sourcesButton
        case .keys: keysButton
        case .shortcuts: shortcutsButton
        case .clipboard: clipboardButton
        case .escape: escapeButton
        case .tab: tabButton
        case .settings: settingsButton
        case .up: RailButton(icon: "chevron.up", label: "Up") { sendKey(keyCode: 126) }
        case .down: RailButton(icon: "chevron.down", label: String(localized: "Down")) { sendKey(keyCode: 125) }
        case .left: RailButton(icon: "chevron.left", label: String(localized: "Left")) { sendKey(keyCode: 123) }
        case .right: RailButton(icon: "chevron.right", label: String(localized: "Right")) { sendKey(keyCode: 124) }
        case .delete: RailButton(icon: "delete.backward", label: "Delete") { model.handleBackspace() }
        }
    }

    var dockPageDots: some View {
        let sheets = dockSheets
        let current = dockPage ?? sheets.first?.id
        return HStack(spacing: 0) {
            ForEach(Array(sheets.enumerated()), id: \.element.id) { index, sheet in
                Button {
                    withAnimation(Motion.settle) { dockPage = sheet.id }
                } label: {
                    Circle()
                        .fill(sheet.id == current ? Color.primary : Color.secondary.opacity(0.6))
                        .frame(width: 5, height: 5)
                        .shadow(color: .black.opacity(0.55), radius: 2, y: 1)
                        .frame(width: 16, height: ChromeMetrics.dockPageDotsHeight)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityLabel("\(sheet.spokenName), \(index + 1) of \(sheets.count)")
                .accessibilityAddTraits(sheet.id == current ? [.isSelected] : [])
            }
        }
        .frame(height: ChromeMetrics.dockPageDotsHeight)
    }

    var dockShape: RoundedRectangle {
        RoundedRectangle(
            cornerRadius: dockExpanded
                ? ChromeMetrics.dockExpandedRadius
                : ChromeMetrics.dockCollapsedRadius,
            style: .continuous
        )
    }

    var dockToggle: some View {
        Button {
            withAnimation(Motion.morph) { dockExpanded.toggle() }
            // Expanding and shutting change how many sheets there are, so the one that was showing
            // may be gone afterwards. Where it survives it is kept, which is what stops a press on
            // the chevron from throwing away the user's place; where it does not, the dock goes
            // back to its first sheet rather than to no sheet at all.
            let ids = dockSheets.map(\.id)
            if !ids.contains(dockPage ?? "") { dockPage = ids.first }
        } label: {
            Image(systemName: dockExpanded ? "chevron.up" : "chevron.down")
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(.secondary)
                .frame(maxWidth: .infinity)
                .frame(height: ChromeMetrics.buttonHeight)
                .contentShape(Rectangle())
        }
        .buttonStyle(RailButtonStyle(scale: 0.94, haptic: true))
        .accessibilityLabel(dockExpanded ? "Hide the other controls" : "Show the other controls")
    }

    /// Both keys are given the same frame whatever size they are drawn at, so the row balances
    /// around the stick and the stick lands on the centre exactly. Framed to their own widths,
    /// the smaller Back would leave the stick seven points off the middle, which is the amount
    /// that reads as the screen being slightly crooked rather than as a mistake.
    var portraitPointer: some View {
        HStack(alignment: .center, spacing: ChromeMetrics.panelGap) {
            backKey
                .frame(width: ChromeMetrics.quickKeySize, height: ChromeMetrics.quickKeySize)
            joystick()
            returnKey
                .frame(width: ChromeMetrics.quickKeySize, height: ChromeMetrics.quickKeySize)
        }
    }
}
