import RemoteCore
import SwiftUI
import UIKit

/// One screenful of the dock: as many buttons as it has cells for.
///
/// The dock stands at one row or at three, so the same list is cut into a different number of
/// these depending on which. Shut, the thirteen controls are three sheets and the eight edits are
/// two; open, each set is a single sheet, because fifteen cells hold the lot.
///
/// **That is the correction.** There were two fixed pages, one per set, and a swipe moved between
/// them. Shut, that meant page one showed five of the thirteen controls while the open page one
/// showed all thirteen, so the same gesture did a different amount of work depending on whether
/// the chevron had been pressed. A sheet is a screenful in both states, and a swipe is always the
/// next one.
///
/// The sets stay apart. Controls come first and edits after, so a sheet never mixes them, and the
/// dock keeps saying which is which.
struct DockSheet: Identifiable {
    let id: String
    /// One of these is empty. Two arrays rather than an enum of the two, because either is handed
    /// straight to the same row builder and an enum would mean matching on every draw.
    let controls: [DockControl]
    let edits: [QuickAction]
    /// The application an app sheet is for. `nil` on the dock's own sheets.
    var applicationName: String? = nil

    /// What this sheet holds, for the one announcement a barred dot cannot make on its own.
    var spokenName: String {
        if let applicationName { return "\(applicationName) shortcuts" }
        return controls.isEmpty ? "Editing shortcuts" : "Dock controls"
    }
}

private extension Array {
    /// The array cut into runs of at most `size`, in order, with no empty run.
    func chunked(into size: Int) -> [[Element]] {
        guard size > 0 else { return isEmpty ? [] : [self] }
        return stride(from: 0, to: count, by: size).map {
            Array(self[$0 ..< Swift.min($0 + size, count)])
        }
    }
}

/// The dock's controls, in the order it draws them.
///
/// A fixed order, in groups of five so each is one sheet shut and one row open: Apps and typing
/// first, then moving, then the rest. The dock used to reorder itself by use, and a button that
/// moves is one nobody can find by memory.
enum DockControl: String, CaseIterable, Identifiable {
    case sources, keys, clipboard, escape, tab
    case left, up, down, right, delete
    case shortcuts, mode, settings

    var id: String { rawValue }

    /// The navigation keys as a group, for the rail that still draws them as one.
    static let navigation: [DockControl] = [.up, .down, .left, .right, .delete]
}

/// The portrait dock and the shortcuts panel.
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

            if let profile = activeApplicationProfile {
                applicationActions(profile)
            }

            MacroBar()

            functionKeyRow

            HStack(spacing: 10) {
                ModifierBar()
                Spacer()
                Button(model.keyboardMode.label) {
                    model.setKeyboardMode(model.keyboardMode == .unicode ? .keycode : .unicode)
                }
                .font(.caption.weight(.semibold))
                .buttonStyle(.bordered)
            }

            arrowStrip()
        }
        .padding(10)
        .glassSurface(in: RoundedRectangle(cornerRadius: 22, style: .continuous))
        .padding(.horizontal, 10)
        .reportChromeFrame(.panel, into: $chromeFrames)
        .transition(.move(edge: .bottom).combined(with: .opacity))
    }

    /// What the Mac is showing, if we know anything about it.
    ///
    /// The bundle identifier arrives with the catalogue — every picker row already carries one —
    /// so this needs nothing from the host beyond what is already on the wire. See
    /// ``ApplicationActions`` for the table and for why an unknown application resolves to nil
    /// rather than to a guess.
    var activeApplicationProfile: ApplicationProfile? {
        guard let activeSourceID = model.activeSourceID else { return nil }
        let bundleID = model.catalog?.all.first { $0.id == activeSourceID }?.bundleIdentifier
        return ApplicationActions.profile(forBundleID: bundleID)
    }

    /// The keystrokes that only make sense for what is running, above the ones that make sense
    /// for everything.
    ///
    /// The macro bar below is the same seventeen keys whatever is on screen, which is the right
    /// answer for a list that has to work everywhere and the wrong one for a terminal: the keys
    /// a shell wants are not the keys a browser wants, and the person driving a shell from a
    /// phone knows exactly which ones they want and cannot reach them.
    ///
    /// Absent entirely for an application nobody has written a profile for, rather than shown
    /// empty. A heading with nothing under it is worse than no heading.
    func applicationActions(_ profile: ApplicationProfile) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            SectionLabel(profile.name)

            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 6) {
                    ForEach(profile.actions) { action in
                        Button {
                            sendKey(keyCode: action.keyCode, modifiers: action.modifiers)
                        } label: {
                            Text(action.title)
                                .font(.system(size: 14, weight: .medium))
                                .padding(.horizontal, 12)
                                .frame(height: 34)
                                .glassSurface(
                                    in: RoundedRectangle(cornerRadius: 9, style: .continuous),
                                    interactive: true
                                )
                        }
                        .buttonStyle(RailButtonStyle(scale: 0.86, haptic: true))
                        // The keystroke is the visible label and the reason is not, so the
                        // reason is what gets spoken.
                        .accessibilityLabel(action.detail)
                    }
                }
                .padding(.horizontal, 2)
            }
        }
    }

    /// The arrow keys, plus the two keys a software keyboard cannot send as navigation.
    ///
    /// A single row rather than the inverted T of a physical cluster: this shares a panel with
    /// the macros and the modifiers, and three rows of keys would make it taller than the thing
    /// it is helping with.
    ///
    /// Two homes, because the phone holds no text: the sentence being typed is on the Mac, so sending
    /// the caret back through it is the only way to edit the middle of a line.
    ///
    /// - Parameter withReturn: the dock's row carries Return because it is that panel's whole
    ///   navigation row; the keyboard bar's does not, because the row above it has a Return of its own.
    /// F1 to F12, which a phone keyboard cannot send. Through ``sendKey(keyCode:modifiers:)``, so a
    /// latched modifier applies: ⌘ then F5 is VoiceOver, ⌃ then F2 the menu bar.
    var functionKeyRow: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 6) {
                ForEach(Array(Self.functionKeyCodes.enumerated()), id: \.offset) { index, keyCode in
                    Button {
                        sendKey(keyCode: keyCode)
                    } label: {
                        Text("F\(index + 1)")
                            .font(.system(size: 14, weight: .medium).monospacedDigit())
                            .frame(minWidth: 34)
                            .padding(.horizontal, 6)
                            .frame(height: 34)
                            .glassSurface(in: RoundedRectangle(cornerRadius: 9, style: .continuous), interactive: true)
                    }
                    .buttonStyle(RailButtonStyle(scale: 0.86, haptic: true))
                    .accessibilityLabel("F\(index + 1)")
                }
            }
            .padding(.horizontal, 2)
        }
    }

    /// The Mac's virtual key codes for F1 to F12, in order. They are not sequential.
    static let functionKeyCodes: [UInt16] = [122, 120, 99, 118, 96, 97, 98, 100, 101, 109, 103, 111]

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

    /// How tall the dock stands at the moment, card and dots together.
    ///
    /// The one piece of portrait chrome whose height changes, and the pointer above it is placed
    /// from it rather than from a second number that would have to be kept in step. Read from the
    /// same constants the dock is built from, so opening it lifts the pointer by exactly the row
    /// that appeared.
    ///
    /// The dots are included because they are standing on the picture too: a pointer placed from
    /// the card alone would be lifted by a gap short, and would overlap the dots it was meant to
    /// clear.
    var dockHeight: CGFloat {
        dockCardHeight + ChromeMetrics.dockDotsGap + ChromeMetrics.dockPageDotsHeight
    }

    /// How tall the glass card is: the pager, the chevron, and the padding around them.
    var dockCardHeight: CGFloat {
        dockExpanded ? ChromeMetrics.dockExpandedHeight : ChromeMetrics.dockCollapsedHeight
    }

    /// How tall the dock's rows are right now, without the dots or the padding around them.
    ///
    /// The pager is given exactly this, so a page is the rows and nothing else. Handed the whole
    /// dock it would scroll into the dots' strip as well, and a page would settle with its last
    /// line of buttons a strip short of where it belongs.
    var dockGridHeight: CGFloat {
        dockExpanded ? ChromeMetrics.dockExpandedGridHeight : ChromeMetrics.buttonHeight
    }

    /// The same controls as the landscape rails, in a bar that opens like the status pill does.
    ///
    /// Eight buttons across a phone held upright is a bar with no room left for the picture, and
    /// four of those eight are reached for continuously while the other four are not. So the
    /// shut rail is the four that are, and the chevron at the end of the row opens it onto the
    /// rest — the same gesture, the same spring and the same morphing corner as the pill above
    /// it, because they are the same kind of object: a bar of glass that grows when asked.
    ///
    /// The two rows share a column grid, the chevron's column included. Row two's four buttons
    /// are inset by exactly the chevron's width so that they line up under row one's — a second
    /// row whose buttons sat half a button to the left of the ones above it is the sort of thing
    /// nobody can name and everybody can see.
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
                // Paging rather than free scrolling, so a sheet is either wholly here or wholly
                // gone. A dock resting half way between two sheets is a column of buttons half
                // off the edge of the glass, and a thumb aiming at one has no way to know which
                // half of it will be under the finger when the swipe settles.
                .scrollTargetBehavior(.paging)
                .scrollPosition(id: $dockPage)

                dockToggle
                    .frame(width: ChromeMetrics.dockToggleWidth)
            }
            // One row shut, three open. The pager is the whole of the dock in both states and
            // this is the only measurement that differs between them, so a swipe means the
            // same thing either way.
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
            //
            // The glass stops at this frame and the dots are outside it. That is the whole reason
            // the card is one row thick standing shut: with the dots drawn inside, the material
            // had to cover them too, and a bar of buttons ended up two rows tall.
            .frame(width: width, height: dockCardHeight)
            .clipShape(dockShape)
            .glassSurface(in: dockShape)

            dockPageDots
        }
        .frame(width: width, height: dockHeight)
    }

    /// One page of the dock: five columns, and as many rows as the dock is standing at.
    ///
    /// The rows used to be written out one button at a time, and that is what said where each one
    /// sat. Now the page is cut from ``DockControl``'s order, which is where the position lives.
    ///
    /// One row shut and three open, so a swipe means the same thing in both states. Both pages are
    /// the same width and their rows are the same height, so a swipe slides the grid sideways
    /// rather than redrawing it, and a button on the second page lands on a row line the first page
    /// already drew. That is what keeps the dock one object rather than two bars.
    ///
    /// The empty cells that pad the last row are the same size as a full one, for the reason the
    /// hand-written rows carried them: a row that dropped a column would divide its width between
    /// what was left and put every button in it under the gap between the two above.
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

    /// Every sheet of the dock, in the order they are swiped through.
    ///
    /// Controls first and edits after, each cut into runs of as many buttons as the dock has cells
    /// for. Shut that is five, so the twelve controls are three sheets and the eight edits two;
    /// open it is fifteen, so each set is one sheet. The dots follow from this rather than being a
    /// fixed pair, which is the point: what a swipe moves by is the same in both states.
    ///
    /// The count is twelve since the desktops button went, and the sheet sums are unchanged by it:
    /// twelve still cuts into three runs of five and below.
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

    /// One sheet, whichever it is.
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

    /// One control of the dock, by name.
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
        case .down: RailButton(icon: "chevron.down", label: "Down") { sendKey(keyCode: 125) }
        case .left: RailButton(icon: "chevron.left", label: "Left") { sendKey(keyCode: 123) }
        case .right: RailButton(icon: "chevron.right", label: "Right") { sendKey(keyCode: 124) }
        case .delete: RailButton(icon: "delete.backward", label: "Delete") { model.handleBackspace() }
        }
    }

    /// Which sheet the dock is on, and the way to any of the others.
    ///
    /// One dot per sheet, so the count changes with the dock: five standing shut, two open. That
    /// is honest rather than tidy, and it is the same thing the swipe does, which is the property
    /// worth keeping.
    ///
    /// Pressable as well as drawn. Dots that only report are dots that tell the user where they
    /// are and then make them swipe to prove it, and on a bar this wide they are the smaller
    /// target of the two, so they are the ones with a reason to be tappable.
    ///
    /// Bare marks, with a shadow rather than a backing. They sit over the picture, so they need
    /// something to hold them apart from whatever is behind them, and a shadow does that without
    /// putting a second pane of glass under a bar that is already made of it. A capsule holding a
    /// couple of five-point dots is more glass than indicator, which is the wrong way round.
    var dockPageDots: some View {
        let sheets = dockSheets
        // Nothing yet means the first sheet, which is where the pager sits before it is touched.
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
                        // The full height of the strip, so a mark this small still has a tap
                        // target a thumb can find without aiming.
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

    /// The dock's outline, in whichever state it is in — see ``pillShape``, which this is a
    /// second reading of. The buttons divide whatever width they are given, so the two states
    /// differ in height alone; the corner is what tells the eye the bar has opened rather than
    /// been swapped for a taller one.
    var dockShape: RoundedRectangle {
        RoundedRectangle(
            cornerRadius: dockExpanded
                ? ChromeMetrics.dockExpandedRadius
                : ChromeMetrics.dockCollapsedRadius,
            style: .continuous
        )
    }

    /// The dock's own chevron: the one thing in the row that is not a control for the Mac.
    ///
    /// Fixed at the trailing edge, outside the pager, so the buttons move under it rather than
    /// with it. Two things come of that: it stays under the thumb that just pressed it, and it
    /// can be pressed from either page, where as a cell of the first page it could only be
    /// reached by swiping back to that page first.
    ///
    /// It is wordless because it says nothing about the Mac; it only says there is more bar.
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

    /// The pointer in portrait: the stick above the dock, with the two keys either side of it.
    ///
    /// Return moves off the stick's axis to its right, and Back keeps the left, so the row is
    /// only ever one control tall — a key stacked above the stick would be a key over the middle
    /// of the picture, which is the part of the Mac the user is trying to see.
    ///
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
