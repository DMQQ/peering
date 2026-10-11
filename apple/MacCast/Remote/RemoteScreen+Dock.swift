import RemoteCore
import SwiftUI
import UIKit

struct DockSheet: Identifiable {
    let id: String
    let controls: [DockControl]
    let edits: [QuickAction]
    var applicationName: String? = nil

    var spokenName: String {
        if let applicationName { return String(localized: "\(applicationName) shortcuts") }
        return controls.isEmpty ? String(localized: "Editing shortcuts") : String(localized: "Dock controls")
    }
}

private extension Array {
    func chunked(into size: Int) -> [[Element]] {
        guard size > 0 else { return isEmpty ? [] : [self] }
        return stride(from: 0, to: count, by: size).map {
            Array(self[$0 ..< Swift.min($0 + size, count)])
        }
    }
}

struct ShortcutSets: View {
    let application: (name: String, row: AnyView)?
    let functionKeys: AnyView

    private enum Set: Hashable { case application, macros, functionKeys }

    @State private var chosen: Set?

    static let columns = [GridItem(.adaptive(minimum: 76), spacing: 8)]

    private var sets: [(Set, String)] {
        var sets: [(Set, String)] = []
        if let application { sets.append((.application, application.name)) }
        sets.append((.macros, String(localized: "Shortcuts")))
        sets.append((.functionKeys, "F1–F12"))
        return sets
    }

    private var shown: Set {
        if let chosen, sets.contains(where: { $0.0 == chosen }) { return chosen }
        return application == nil ? .macros : .application
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Picker("Shortcut set", selection: Binding(
                get: { shown },
                set: { set in withAnimation(Motion.settle) { chosen = set } }
            )) {
                ForEach(sets, id: \.0) { set, title in
                    Text(title).tag(set)
                }
            }
            .pickerStyle(.segmented)

            ViewThatFits(in: .vertical) {
                keys
                ScrollView(.vertical, showsIndicators: false) { keys }
                    .frame(maxHeight: 208)
            }
            .id(shown)
            .transition(.blurReplace(.downUp))
        }
    }
}

extension ShortcutSets {
    @ViewBuilder
    private var keys: some View {
        switch shown {
        case .application: application?.row
        case .macros: MacroBar()
        case .functionKeys: functionKeys
        }
    }
}

extension View {
    func keyChip() -> some View {
        lineLimit(1)
            .minimumScaleFactor(0.6)
            .frame(maxWidth: .infinity, minHeight: 44)
            .background(ColorPalette.ink.opacity(0.1), in: RoundedRectangle(cornerRadius: 9, style: .continuous))
            .contentShape(RoundedRectangle(cornerRadius: 9, style: .continuous))
    }
}

enum DockControl: String, CaseIterable, Identifiable {
    case sources, keys, clipboard, shortcuts, tab
    case left, up, down, right, delete
    case escape, mode, settings

    var id: String { rawValue }

    static let navigation: [DockControl] = [.up, .down, .left, .right, .delete]
}

extension RemoteScreen {
    var shortcutsPanel: some View {
        VStack(spacing: 8) {
            if model.showKeyboard, !model.typedPreview.isEmpty {
                HStack {
                    Text(model.typedPreview)
                        .font(.system(.footnote, design: .monospaced))
                        .lineLimit(1)
                        // Head-truncate so the most-recently-typed characters stay visible
                        // when the preview is wider than the available space.
                        .truncationMode(.head)
                    Spacer()
                }
                .padding(.horizontal, 12)
                .padding(.vertical, 6)
                .background(.ultraThinMaterial)
                .clipShape(RoundedRectangle(cornerRadius: 8))
            }

            ShortcutSets(
                application: activeApplicationProfile.map { profile in
                    (profile.name, AnyView(applicationActions(profile)))
                },
                functionKeys: AnyView(functionKeyRow)
            )

            ModifierBar(large: true)

            arrowCluster
        }
        .padding(10)
    }

    var activeApplicationProfile: ApplicationProfile? {
        guard let activeSourceID = model.activeSourceID else { return nil }
        let bundleID = model.catalog?.all.first { $0.id == activeSourceID }?.bundleIdentifier
        return ApplicationActions.profile(forBundleID: bundleID)
    }

    func applicationActions(_ profile: ApplicationProfile) -> some View {
        LazyVGrid(columns: ShortcutSets.columns, spacing: 8) {
                ForEach(profile.actions) { action in
                    Button {
                        sendKey(keyCode: action.keyCode, modifiers: action.modifiers)
                    } label: {
                        Text(action.title)
                            .font(.system(size: 15, weight: .medium))
                            .padding(.horizontal, 8)
                            .keyChip()
                    }
                    .buttonStyle(RailButtonStyle(scale: 0.86, haptic: true))
                    // The keystroke is the visible label and the reason is not, so the
                    // reason is what gets spoken.
                    .accessibilityLabel(action.detail)
                }
        }
    }

    /// Two homes, because the phone holds no text: the sentence being typed is on the Mac, so sending
    /// the caret back through it is the only way to edit the middle of a line.
    /// F1 to F12, which a phone keyboard cannot send. Through ``sendKey(keyCode:modifiers:)``, so a
    /// latched modifier applies: ⌘ then F5 is VoiceOver, ⌃ then F2 the menu bar.
    var functionKeyRow: some View {
        FunctionKeyGrid(
            sendKey: { sendKey(keyCode: $0) },
            sendAction: { code in
                model.send(.keyDown(keyCode: code, modifiers: .topRowAction))
                model.send(.keyUp(keyCode: code, modifiers: .topRowAction))
            }
        )
    }

    var arrowCluster: some View {
        HStack(alignment: .bottom, spacing: 8) {
            panelKey("delete.backward", label: "Delete", width: 64) { model.handleBackspace() }
            panelKey("return", label: "Enter", width: 64) { model.pressReturn() }
            Spacer(minLength: 0)
            VStack(spacing: 6) {
                panelKey("chevron.up", label: "Up arrow") { sendKey(keyCode: 126) }
                HStack(spacing: 6) {
                    panelKey("chevron.left", label: "Left arrow") { sendKey(keyCode: 123) }
                    panelKey("chevron.down", label: "Down arrow") { sendKey(keyCode: 125) }
                    panelKey("chevron.right", label: "Right arrow") { sendKey(keyCode: 124) }
                }
            }
        }
    }

    private func panelKey(
        _ icon: String,
        label: String,
        width: CGFloat = 52,
        action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            Image(systemName: icon)
                .font(.system(size: 15, weight: .semibold))
                .frame(width: width, height: 40)
                .background(ColorPalette.ink.opacity(0.1), in: RoundedRectangle(cornerRadius: 9, style: .continuous))
                .contentShape(RoundedRectangle(cornerRadius: 9, style: .continuous))
        }
        .buttonStyle(RailButtonStyle(scale: 0.86, haptic: true))
        .accessibilityLabel(label)
    }

    func arrowStrip(withReturn: Bool = true) -> some View {
        HStack(spacing: 4) {
            compactKeyButton(icon: "chevron.left", keyCode: 123)
                .accessibilityLabel("Left arrow")
            compactKeyButton(icon: "chevron.up", keyCode: 126)
                .accessibilityLabel("Up arrow")
            compactKeyButton(icon: "chevron.down", keyCode: 125)
                .accessibilityLabel("Down arrow")
            compactKeyButton(icon: "chevron.right", keyCode: 124)
                .accessibilityLabel("Right arrow")
            if withReturn {
                compactKeyButton(icon: "return", keyCode: 36) { model.pressReturn() }
                    .accessibilityLabel("Enter")
            }
            // Through the model rather than as a bare keycode, so the typed preview loses the
            // character with the Mac's own line: sent directly, the Mac deleted and the preview
            // kept what it had, which is a bar showing text that no longer exists anywhere.
            compactCapButton(icon: "delete.backward") { model.handleBackspace() }
                .accessibilityLabel("Delete")
        }
    }

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
    /// the smaller Back would leave the stick seven points off the middle — which is the amount
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

struct FunctionKeyGrid: View {
    let sendKey: (UInt16) -> Void
    let sendAction: (UInt16) -> Void

    @State private var fnLatched = false

    /// F5 and F6 have no action here: dictation and Do Not Disturb cannot be posted from outside.
    private static let icons: [String?] = [
        "sun.min", "sun.max", "rectangle.3.group", "magnifyingglass", nil, nil,
        "backward", "playpause", "forward", "speaker.slash", "speaker.wave.1", "speaker.wave.3",
    ]

    var body: some View {
        LazyVGrid(columns: ShortcutSets.columns, spacing: 8) {
            Button {
                fnLatched.toggle()
            } label: {
                Text("fn")
                    .font(.system(size: 15, weight: .medium))
                    .keyChip()
                    .background(
                        fnLatched ? ColorPalette.selectedFill : .clear,
                        in: RoundedRectangle(cornerRadius: 9, style: .continuous)
                    )
            }
            .buttonStyle(RailButtonStyle(scale: 0.86, haptic: true))
            .accessibilityLabel("Function keys")
            .accessibilityAddTraits(fnLatched ? .isSelected : [])

            ForEach(0..<12, id: \.self) { index in
                let code = MediaKey.functionKeyCodes[index]
                let icon = Self.icons[index]
                Button {
                    if !fnLatched, icon != nil { sendAction(code) } else { sendKey(code) }
                } label: {
                    VStack(spacing: 2) {
                        if !fnLatched, let icon {
                            Image(systemName: icon)
                                .font(.system(size: 15, weight: .medium))
                        }
                        Text("F\(index + 1)")
                            .font(.system(size: fnLatched || icon == nil ? 15 : 10, weight: .medium).monospacedDigit())
                            .foregroundStyle(fnLatched || icon == nil ? ColorPalette.ink : ColorPalette.ink.opacity(0.55))
                    }
                    .keyChip()
                }
                .buttonStyle(RailButtonStyle(scale: 0.86, haptic: true))
                .accessibilityLabel("F\(index + 1)")
            }
        }
    }
}
