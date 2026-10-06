import MacCastKit
import RemoteCore
import SSHCore
import SwiftUI

/// One shell as its own screen. The Mac owns the PTY; this view displays its bounded byte history and sends exact input bytes over the authenticated session.
struct TerminalScreen: View {
    @State var currentID: UUID

    init(terminalID: UUID) {
        _currentID = State(initialValue: terminalID)
    }

    @Environment(SessionModel.self) var model
    @Environment(\.dismiss) var dismiss

    @State var command = ""
    /// A plain state flag, not `@FocusState`: nothing claims SwiftUI focus for the `UITextField`, so SwiftUI reset it to nil on each keystroke and `updateUIView` resigned the keyboard.
    @State var inputFocused = false

    /// Whether new output pulls the view down. Not `.defaultScrollAnchor(.bottom)`, which dragged the view back on every redraw.
    @State var stickToBottom = true

    @Environment(QuickCommands.self) var quickCommands
    @State var isEditingQuickCommands = false

    @State var showsHistory = false

    @State var isBrowsing = false
    /// Whether dotfiles are listed. The browser filters them itself, so the Mac sends everything.
    @State var showsHiddenFiles = false

    @State var pendingClose: RemoteTerminal?
    @State var renamingID: UUID?
    @State var renameText = ""

    @AppStorage(PreferenceKeys.hasSeenTourTerminal) var hasSeenTourTerminal = false

    /// The log's type size, shared with the SSH terminal.
    @AppStorage(PreferenceKeys.terminalTextSize) var textSize = TerminalMetrics.TextSize.regular.rawValue

    var fontSize: CGFloat { TerminalMetrics.TextSize.named(textSize).points }

    var dueTerminalTours: [Tour] {
        hasSeenTourTerminal ? [] : [.terminal]
    }

    var terminal: RemoteTerminal? {
        model.terminals.first { $0.id == currentID }
    }

    /// `nil` while the Mac's home path is unresolved. Kept on the model so it survives a rebuild or tab switch.
    var browsingPath: String? {
        model.browsingPath(for: currentID)
    }

    var body: some View {
        Group {
            if let terminal {
                VStack(spacing: 0) {
                    tabStrip
                    content(terminal)
                }
            } else {
                ended
            }
        }
        .background(Color.black)
        // One flag shared with the SSH terminal, so the tips are not shown twice.
        .firstRunTours(dueTerminalTours) { $0.markSeen() }
        .navigationTitle(terminal?.name ?? String(localized: "Terminal"))
        .navigationBarTitleDisplayMode(.inline)
        // The header takes the terminal's colour; the system bar material looked like another app's chrome.
        .toolbarBackground(Color.black, for: .navigationBar)
        .toolbarBackground(.visible, for: .navigationBar)
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                if let terminal, terminal.isRunning || isBrowsing {
                    TerminalModeButton(isBrowsing: isBrowsing, carriesOwnSurface: false) { toggleBrowsing(terminal) }
                }
            }
            ToolbarItem(placement: .topBarTrailing) {
                if let terminal {
                    Button { requestClose(terminal) } label: {
                        Image(systemName: "xmark")
                    }
                    .accessibilityLabel(Text("End \(terminal.name)"))
                }
            }
            ToolbarItemGroup(placement: .keyboard) {
                Spacer()
                Button("Done") {
                    UIApplication.shared.sendAction(#selector(UIResponder.resignFirstResponder), to: nil, from: nil, for: nil)
                    inputFocused = false
                }
            }
        }
        .terminalEndPrompt(
            name: pendingClose?.name ?? "",
            detail: String(localized: "The shell running in it stops. Your Mac and the rest of the terminals are left alone."),
            isPresented: Binding(
                get: { pendingClose != nil },
                set: { if !$0 { pendingClose = nil } }
            ),
            onEnd: {
                guard let terminal = pendingClose else { return }
                model.closeTerminal(terminal.id)
                pendingClose = nil
                dismiss()
            }
        )
        .onAppear { model.selectTerminal(currentID) }
        .onChange(of: currentID) { _, id in
            model.selectTerminal(id)
            guard isBrowsing,
                  model.terminals.first(where: { $0.id == id })?.isRunning == true else { return }
            model.listDirectory(model.browsingPath(for: id), sessionID: id)
        }
        // A shell that is gone leaves the screen showing another one or leaves the cover. Nothing here fires for a shell being added.
        .onChange(of: model.terminals.map(\.id)) { _, ids in
            guard !ids.contains(currentID) else { return }
            if let next = ids.first {
                currentID = next
            } else {
                dismiss()
            }
        }
        .alert("Rename", isPresented: Binding(
            get: { renamingID != nil },
            set: { if !$0 { renamingID = nil } }
        )) {
            TextField("Name", text: $renameText)
            Button("Cancel", role: .cancel) { renamingID = nil }
            Button("Save") {
                if let id = renamingID {
                    model.renameTerminal(id, to: renameText.trimmingCharacters(in: .whitespacesAndNewlines))
                }
                renamingID = nil
            }
        }
        .sheet(isPresented: $isEditingQuickCommands) {
            SSHQuickCommandsEditor(commands: quickCommands)
        }
    }

    var tabStrip: some View {
        TabStrip(items: model.terminals, selection: currentID) { terminal, isSelected in
            chip(terminal, isSelected: isSelected)
        } accessory: {
            EmptyView()
        }
    }

    func chip(_ terminal: RemoteTerminal, isSelected: Bool) -> some View {
        let state = terminal.state
        return TabChip(
            isSelected: isSelected,
            onSelect: { withAnimation(Motion.tap) { currentID = terminal.id } },
            onClose: { requestClose(terminal) },
            // The cross is on the tab, as in the SSH terminal: a fixed close button closed the selected tab, not the one being pointed at.
            closeLabel: String(localized: "Close \(terminal.name)")
        ) {
            mark(for: state)
        } name: {
            TabName(
                text: terminal.name,
                isSelected: isSelected,
                colour: nameColour(for: state, isSelected: isSelected)
            )
        }
        // Simultaneous rather than counted taps: a counted single tap waits out the double-tap window.
        .simultaneousGesture(TapGesture(count: 2).onEnded { beginRename(terminal) })
        .contextMenu {
            Button("Rename", systemImage: "character.cursor.ibeam") { beginRename(terminal) }
                .menuInk()
            Button("End", systemImage: "xmark", role: .destructive) { requestClose(terminal) }
                .menuDanger()
        }
    }

    func beginRename(_ terminal: RemoteTerminal) {
        renameText = terminal.name
        renamingID = terminal.id
    }

    @ViewBuilder
    func mark(for state: TerminalState) -> some View {
        switch state {
        case .starting:
            ProgressView()
                .controlSize(.mini)
                .tint(.secondary)
        case .attention(let kind):
            Image(systemName: kind == .password ? "lock.fill" : "questionmark.circle.fill")
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(ColorPalette.accent)
        case .failed:
            Image(systemName: "exclamationmark.triangle.fill")
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(ColorPalette.danger)
        case .running:
            Image(systemName: "terminal")
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(.secondary)
        case .stopped:
            Image(systemName: "terminal")
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(ColorPalette.ink.opacity(0.3))
        }
    }

    /// A state's tint wins over selection, so a terminal wanting a password is found at a glance.
    func nameColour(for state: TerminalState, isSelected: Bool) -> Color {
        if let tint = state.tint { return tint }
        if state == .stopped { return ColorPalette.ink.opacity(0.3) }
        return isSelected ? ColorPalette.ink : Color.secondary
    }

    @ViewBuilder
    private func content(_ terminal: RemoteTerminal) -> some View {
        VStack(spacing: 0) {
            if isBrowsing {
                browsing(terminal)
            } else {
                output(terminal)
                if showsHistory, !model.terminalHistory.isEmpty { historyStrip(terminal.id) }
                // `self.` is load-bearing: unqualified, `send` resolves to Darwin's POSIX `send(2)`.
                TerminalDeck(
                    commands: quickCommands.all,
                    run: { model.sendTerminalInput($0.command, to: terminal.id) },
                    remove: { quickCommands.delete($0) },
                    // Making a command is Pro; running a saved one and the keys are not.
                    edit: { isEditingQuickCommands = true },
                    send: { self.send($0, to: terminal.id) },
                    isEnabled: terminal.isRunning
                )
                .tourAnchor(.terminalDeck)
                input(terminal)
                    .tourAnchor(.terminalInput)
            }
        }
    }

    private var ended: some View {
        VStack(spacing: 6) {
            Text("This terminal has ended.")
                .font(.subheadline.weight(.medium))
                .foregroundStyle(ColorPalette.ink)
            Text("Open a new one from Mac terminals.")
                .font(.footnote)
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    func requestClose(_ terminal: RemoteTerminal) {
        if terminal.isRunning || !terminal.output.isEmpty {
            pendingClose = terminal
        } else {
            model.closeTerminal(terminal.id)
            dismiss()
        }
    }

    var hairline: some View {
        Rectangle()
            .fill(Color.white.opacity(0.08))
            .frame(height: 1)
    }

    /// A `ZStack` rather than a `Group`, so the two states can cross-fade.
    func output(_ terminal: RemoteTerminal) -> some View {
        ZStack {
            if terminal.output.isEmpty, terminal.isRunning {
                TerminalStarting()
                    .transition(.opacity)
            } else {
                log(terminal)
                    .transition(.opacity)
            }
        }
        .animation(Motion.tap, value: terminal.output.isEmpty)
    }

    func log(_ terminal: RemoteTerminal) -> some View {
        ScrollViewReader { reader in
            // Two scroll views rather than one two-axis one: `scrollTo(anchor: .bottom)` on a two-axis view also walked the view rightward on every line.
            ScrollView(.vertical) {
                ScrollView(.horizontal, showsIndicators: false) {
                    Text(coloured(terminal))
                        .font(.system(size: fontSize, design: .monospaced))
                        .textSelection(.enabled)
                        // Lines are not wrapped, so output lines up in columns.
                        .fixedSize(horizontal: true, vertical: false)
                        .frame(maxWidth: .infinity, alignment: .topLeading)
                        .padding(12)
                }
                // A one-point view at the end of the text is the scroll target, not the text itself, whose width dragged the view sideways.
                Color.clear.frame(height: 1).id("terminal-end")
            }
            // Not `.defaultScrollAnchor(.bottom)`: it pins the anchor as content grows, so every redraw dragged the view down.
            .onScrollGeometryChange(for: Bool.self) { geometry in
                let fromBottom = geometry.contentSize.height
                    - (geometry.contentOffset.y + geometry.containerSize.height)
                return fromBottom <= Self.bottomSlack
            } action: { _, atBottom in
                stickToBottom = atBottom
            }
            // Dragging the history puts the keyboard away.
            .scrollDismissesKeyboard(.interactively)
            // Pressing the output focuses the field, since typing is what comes next; long press still selects.
            .onTapGesture { inputFocused = true }
            .onChange(of: terminal.output.count) { _, _ in
                guard stickToBottom else { return }
                reader.scrollTo("terminal-end", anchor: .bottom)
            }
            .task {
                reader.scrollTo("terminal-end", anchor: .bottom)
            }
            .background {
                // The Mac is told the terminal's size, measured on the log (not the key strip or input row), or shells run at the default 80x24.
                GeometryReader { geometry in
                    Color.clear.onChange(of: geometry.size, initial: true) { _, size in
                        applySize(size, to: terminal)
                    }
                }
            }
        }
    }

    /// Not zero: a scroll view rarely lands exactly on the edge.
    static let bottomSlack: CGFloat = 24

    /// Reported, not kept: rows only grow, which keeps the keyboard from resizing a terminal.
    func applySize(_ size: CGSize, to terminal: RemoteTerminal) {
        guard size.width > 0, size.height > 0 else { return }
        #if DEBUG
        TerminalTrace.write(["k": "apply", "w": size.width, "h": size.height, "font": fontSize, "c": TerminalMetrics.columns(forWidth: size.width, fontSize: fontSize), "r": TerminalMetrics.rows(forHeight: size.height, fontSize: fontSize)])
        #endif
        model.resizeTerminal(
            terminal.id,
            columns: TerminalMetrics.columns(forWidth: size.width, fontSize: fontSize),
            rows: TerminalMetrics.rows(forHeight: size.height, fontSize: fontSize)
        )
    }

    /// Rendered through ``TerminalScreen`` (not the line-based sanitizer) so cursor addressing and the shell's colours work.
    func coloured(_ terminal: RemoteTerminal) -> AttributedString {
        guard !terminal.output.isEmpty else {
            // Only reached by a terminal that stopped without printing; the running-and-empty case is ``TerminalStarting``.
            return AttributedString(terminal.isRunning ? String(localized: "Starting login shell…") : String(localized: "Nothing was printed."))
        }

        return TerminalPalette.attributed(terminal.screen.styled, fontSize: fontSize)
    }

    /// Only commands, not results: the PTY has no notion of where output ends. A tap fills the field rather than sending.
    func historyStrip(_ id: UUID) -> some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 6) {
                Image(systemName: "clock.arrow.circlepath")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(.tertiary)
                ForEach(model.terminalHistory, id: \.self) { command in
                    Button {
                        self.command = command
                        inputFocused = true
                    } label: {
                        Text(command)
                            .font(.system(size: 11, design: .monospaced))
                            .lineLimit(1)
                            .padding(.horizontal, 9)
                            .padding(.vertical, 5)
                            .background(Color.white.opacity(0.08), in: Capsule())
                    }
                    .buttonStyle(.plain)
                    .disabled(!(terminal?.isRunning ?? false))
                }
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 7)
        }
        .background(Color.white.opacity(0.02))
        .overlay(alignment: .top) { hairline }
    }

    func input(_ terminal: RemoteTerminal) -> some View {
        HStack(spacing: 8) {
            // Keyboard dismiss at the far end from send, always shown so layout does not jump on focus.
            TerminalHideKeyboardKey {
                UIApplication.shared.sendAction(#selector(UIResponder.resignFirstResponder), to: nil, from: nil, for: nil)
            }

            if !model.terminalHistory.isEmpty {
                Button {
                    withAnimation(Motion.tap) { showsHistory.toggle() }
                } label: {
                    Image(systemName: "clock.arrow.circlepath")
                        .font(.system(size: 15, weight: .semibold))
                        .foregroundStyle(showsHistory ? ColorPalette.accent : Color.secondary)
                        .frame(width: 30, height: 30)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityLabel(showsHistory ? "Hide command history" : "Show command history")
            }

            TerminalCommandField(
                text: $command,
                isFocused: Binding(
                    get: { inputFocused },
                    set: { inputFocused = $0 }
                ),
                placeholder: terminal.isRunning ? String(localized: "Type a command") : String(localized: "Process exited"),
                isEnabled: terminal.isRunning,
                onSubmit: { submit(to: terminal.id) }
            )
            // A height, not a minimum: a `UITextField` has no intrinsic height SwiftUI holds, so `minHeight` grew the row to a 328pt band.
            .frame(height: TerminalCommandField.height)
            Button { submit(to: terminal.id) } label: {
                Image(systemName: "arrow.up.circle.fill").font(.title2)
            }
            .disabled(!terminal.isRunning || command.isEmpty)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
        .background(Color.black)
        .overlay(alignment: .top) { hairline }
    }
}
