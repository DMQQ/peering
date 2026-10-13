import PeeringKit
import RemoteCore
import SSHCore
import SwiftUI

/// A shell on a server.
struct SSHTerminalScreen: View {
    let model: SSHModel
    let terminal: SSHTerminal

    /// The saved commands. Owned by the app because the Mac's terminals show the same list.
    @Environment(QuickCommands.self) private var quickCommands

    @AppStorage(PreferenceKeys.hasSeenTourShell) private var hasSeenTourShell = false
    @AppStorage(PreferenceKeys.hasSeenTourTerminal) private var hasSeenTourTerminal = false

    @State private var command = ""
    /// Not @FocusState: the field is a UITextField owning its responder status, and SwiftUI clears a @FocusState no .focused() claimed.
    @State private var inputFocused = false
    /// The last size sent, so a layout pass that did not actually change the number of cells does
    /// not send a window-change request the server has to answer for nothing.
    @State private var lastColumns = 0
    @State private var lastRows = 0
    @State private var stickToBottom = true
    @State private var isEditingQuickCommands = false

    @State private var isBrowsing = false

    @State private var isShowingForwards = false

    private var portsSymbol: String {
        if model.hasBrokenForward(on: terminal.host) { return "exclamationmark.triangle" }
        return model.hasRunningForward(on: terminal.host) ? "point.3.connected.trianglepath.dotted" : "point.3.filled.connected.trianglepath.dotted"
    }

    private var portsTint: Color {
        if model.hasBrokenForward(on: terminal.host) { return ColorPalette.caution }
        return model.hasRunningForward(on: terminal.host) ? ColorPalette.accent : .secondary
    }
    @State private var showsHiddenFiles = false

    var body: some View {
        VStack(spacing: 0) {
            tabStrip
                .tourAnchor(.shellTabs)
                .terminalEndPrompt(
                    name: model.pendingClose?.title ?? "",
                    detail: String(localized: "The shell on the server stops, along with anything running in it. Your other shells are left alone."),
                    isPresented: Binding(
                        get: { model.pendingClose != nil },
                        set: { if !$0 { model.pendingClose = nil } }
                    ),
                    onEnd: {
                        guard let terminal = model.pendingClose else { return }
                        model.close(terminal)
                        model.pendingClose = nil
                    }
                )
            if isBrowsing {
                browsing
            } else {
                output
                    .tourAnchor(.shellOutput)
                TerminalDeck(
                    commands: quickCommands.all,
                    run: { model.run($0, on: terminal) },
                    remove: { quickCommands.delete($0) },
                    edit: { isEditingQuickCommands = true },
                    send: { model.send(Data($0.utf8), to: terminal) },
                    isEnabled: canType
                )
                .tourAnchor(.terminalDeck)
                input
                    .tourAnchor(.terminalInput)
            }
        }
        // On the screen's own stack: a preference does not travel out through a navigation container.
        .firstRunTours(dueTours) { $0.markSeen() }
        .sheet(isPresented: $isEditingQuickCommands) {
            SSHQuickCommandsEditor(commands: quickCommands)
        }
        .background(ColorPalette.backdrop)
        // No tab bar: this is the Servers tab's root, and the bar would sit a few points under the line the cursor is on.
        .toolbar(.hidden, for: .tabBar)
        // Inline, not a two-line principal item: a taller principal view grows the navigation bar and pushes the tab strip down.
        .navigationTitle(terminal.title)
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .topBarLeading) {
                // Leaving, not hanging up: the shell keeps running and SSHTab offers it back.
                Button("Servers", systemImage: "chevron.left") { model.leaveTerminal() }
            }
            ToolbarItem(placement: .topBarTrailing) {
                // Same button on every plan; on a one-shell plan it is dimmed and the tap opens the plans.
                Button("New shell", systemImage: "plus") {
                    model.openAnotherShell(on: terminal)
                }
                .accessibilityHint("Opens another shell on \(terminal.host.displayName)")
            }
            if !terminal.host.forwards.isEmpty {
                ToolbarItem(placement: .topBarTrailing) {
                    Button("Ports", systemImage: portsSymbol) {
                        isShowingForwards = true
                    }
                    .tint(portsTint)
                    .accessibilityHint("Shows the port forwards this shell is carrying")
                }
            }
            ToolbarItem(placement: .topBarTrailing) {
                Button("End", systemImage: "xmark.circle") { model.requestClose(terminal) }
                    .tint(ColorPalette.danger)
                    .accessibilityHint("Ends the shell on the server")
            }
        }
        .toolbarBackground(ColorPalette.backdrop, for: .navigationBar)
        .toolbarBackground(.visible, for: .navigationBar)
        .toolbarColorScheme(.dark, for: .navigationBar)
        .onAppear {
            inputFocused = true
            InAppBanner.shared.onScreen = .sshTerminal(terminal.id)
        }
        .onDisappear { InAppBanner.shared.leave(.sshTerminal(terminal.id)) }
        .sheet(isPresented: $isShowingForwards) {
            SSHForwardsSheet(host: terminal.host, model: model)
        }
        // Read the new selection's own path, not browsingPath, which still describes the previous shell until the body rebuilds.
        .onChange(of: model.selectedTerminalID) { _, id in
            guard isBrowsing, let id, model.openShells.contains(where: { $0.id == id }) else { return }
            model.listDirectory(model.browsingPath(for: id), sessionID: id)
        }
    }

    // MARK: - Output

    @ViewBuilder
    private var output: some View {
        if terminal.output.isEmpty, case .connecting = terminal.phase {
            TerminalStarting()
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else {
            log
        }
    }

    private var log: some View {
        ScrollViewReader { reader in
            ScrollView(.vertical) {
                ScrollView(.horizontal, showsIndicators: false) {
                    Text(coloured)
                        .font(.system(size: fontSize, design: .monospaced))
                        .textSelection(.enabled)
                        .fixedSize(horizontal: true, vertical: false)
                        .frame(maxWidth: .infinity, alignment: .topLeading)
                        .padding(12)
                }
                Color.clear.frame(height: 1).id(Self.endMarker)
            }
            .scrollDismissesKeyboard(.interactively)
            .onTapGesture { inputFocused = true }
            // Deliberately not .defaultScrollAnchor(.bottom): it re-pins on every redraw, so a full-screen program like htop dragged the view back to the bottom. Follow output only until the user scrolls up.
            .onScrollGeometryChange(for: Bool.self) { geometry in
                let fromBottom = geometry.contentSize.height
                    - (geometry.contentOffset.y + geometry.containerSize.height)
                return fromBottom <= Self.bottomSlack
            } action: { _, atBottom in
                stickToBottom = atBottom
            }
            .onChange(of: terminal.output.count) { _, _ in
                guard stickToBottom else { return }
                reader.scrollTo(Self.endMarker, anchor: .bottom)
            }
            .task {
                // The opening position: a shell already printing opens at the end of its output.
                reader.scrollTo(Self.endMarker, anchor: .bottom)
            }
            .background {
                // Tell the server the size, or full-screen programs lay out for the 80x24 PTY default. Measured on the log, not the screen, since the key strip and input row are not drawable area.
                GeometryReader { geometry in
                    Color.clear.onChange(of: geometry.size, initial: true) { _, size in
                        apply(size)
                    }
                }
            }
        }
    }

    private static let endMarker = "ssh-terminal-end"

    @AppStorage(PreferenceKeys.terminalTextSize) private var textSize = TerminalMetrics.TextSize.regular.rawValue

    private var fontSize: CGFloat { TerminalMetrics.TextSize.named(textSize).points }

    /// Not zero: a scroll view rarely lands exactly on the edge.
    private static let bottomSlack: CGFloat = 24

    private func apply(_ size: CGSize) {
        guard size.width > 0, size.height > 0 else { return }
        let columns = TerminalMetrics.columns(forWidth: size.width, fontSize: fontSize)
        // Rows only ever grow: the keyboard and key deck shorten the log without changing the server's screen.
        let rows = max(lastRows, TerminalMetrics.rows(forHeight: size.height, fontSize: fontSize))
        guard columns != lastColumns || rows != lastRows else { return }
        lastColumns = columns
        lastRows = rows
        model.resize(columns: columns, rows: rows, for: terminal)
    }

    private var coloured: AttributedString {
        guard !terminal.output.isEmpty else {
            return AttributedString(String(localized: "Nothing was printed."))
        }

        var rendered = TerminalPalette.attributed(terminal.styled, fontSize: fontSize)

        if case .ended(let reason) = terminal.phase, let reason {
            var note = AttributedString("\n" + reason + "\n")
            note.foregroundColor = ColorPalette.danger
            rendered.append(note)
        }

        return rendered
    }

    // MARK: - Tabs

    private var tabStrip: some View {
        // The shell this screen is, not the model's current one: each shell has its own screen.
        TabStrip(items: model.openShells, selection: terminal.id) { open, isSelected in
            chip(open, isSelected: isSelected)
        } accessory: {
            TerminalModeButton(isBrowsing: isBrowsing) { toggleBrowsing() }
                .padding(.top, 11)
                .padding(.trailing, 8)
        }
    }

    private var dueTours: [Tour] {
        var due: [Tour] = []
        if !hasSeenTourShell { due.append(.shell) }
        if !hasSeenTourTerminal { due.append(.terminal) }
        return due
    }

    private func chip(_ open: SSHTerminal, isSelected: Bool) -> some View {
        TabChip(
            isSelected: isSelected,
            onSelect: { model.selectedTerminalID = open.id },
            onClose: { model.requestClose(open) },
            // With several shells to the same host, ending one from the toolbar just showed another identical one.
            closeLabel: String(localized: "End \(open.title)")
        ) {
            Circle()
                .fill(statusTint(open))
                .frame(width: 6, height: 6)
        } name: {
            TabName(
                text: open.title,
                isSelected: isSelected,
                colour: isSelected ? ColorPalette.ink : Color.secondary
            )
        }
    }

    private func statusTint(_ open: SSHTerminal) -> Color {
        switch open.phase {
        case .connecting: return ColorPalette.caution
        case .live: return .green
        case .ended: return ColorPalette.danger
        }
    }

    /// A session that has ended takes no input; live controls would write into a dead socket.
    private var canType: Bool {
        if case .ended = terminal.phase { return false }
        return true
    }

    private var hairline: some View {
        Rectangle().fill(Color.white.opacity(0.08)).frame(height: 1)
    }

    // MARK: - Browsing

    private var browsingPath: String? {
        model.browsingPath(for: terminal.id)
    }

    private var folder: String { browsingPath ?? "" }

    private var canMake: Bool { canType && browsingPath != nil }

    /// In place of the terminal, never over it: the log carries the keyboard-focus tap, and the PTY-size reader lives on the log so swapping keeps the change guard a no-op.
    private var browsing: some View {
        VStack(spacing: 0) {
            if let preview = model.filePreview, preview.terminalID == terminal.id {
                FilePreviewPanel(
                    preview: preview,
                    failure: model.browseFailure(preview.path, sessionID: terminal.id),
                    isSaving: model.isSavingFile,
                    saveFailure: model.saveFailure,
                    onRevealPath: { reveal($0) },
                    onClose: { model.closePreview() },
                    onSave: { model.saveFile($0, sessionID: terminal.id) }
                )
            } else {
                FileBrowserPanel(
                    path: browsingPath,
                    directory: model.directory(browsingPath, sessionID: terminal.id),
                    isLoading: model.isLoadingDirectory(browsingPath, sessionID: terminal.id),
                    // An ended shell refuses browse requests, so say so rather than spin. An upload failure uses the folder's own failure slot.
                    failure: canType
                        ? (model.uploadFailure
                            ?? model.browseFailure(browsingPath, sessionID: terminal.id))
                        : String(localized: "This shell has ended. Open a new shell to browse the server's files."),
                    showsHidden: showsHiddenFiles,
                    onToggleHidden: { showsHiddenFiles.toggle() },
                    onOpen: { open($0) },
                    onNavigate: { navigate(to: $0) },
                    onRevealPath: { reveal($0) },
                    onReload: {
                        guard canType else { return }
                        model.listDirectory(browsingPath, sessionID: terminal.id)
                    },
                    // Absent while the shell has ended: there is no connection to send anything down.
                    onUpload: canType
                        ? { model.uploadFile($0, sessionID: terminal.id) }
                        : nil,
                    // An account without file transfer gets the dimmed plan-badged button; nil is a shell that has ended, where a run has nothing to type into.
                    onRun: canType ? { run($0) } : nil,
                    // SFTP has no Trash: say so, since Delete on a Mac is recoverable.
                    deleteHint: String(localized: "This cannot be undone on the server."),
                    // Absent until the folder resolves: `.` would be wherever the server started the shell, not the folder on screen.
                    onCreate: canMake
                        ? { model.createEntry($0, kind: $1, in: folder, sessionID: terminal.id) }
                        : nil,
                    onRename: canMake
                        ? { model.renameEntry($0, to: $1, in: folder, sessionID: terminal.id) }
                        : nil,
                    onDelete: canMake
                        ? { model.deleteEntry($0, in: folder, sessionID: terminal.id) }
                        : nil,
                    isChanging: model.isChangingFile,
                    changeFailure: model.changeFailure,
                    aboveSearch: AnyView(browseControls)
                )
            }
        }
    }

    /// The interrupt key is on it because browsing does not stop a runaway command and the key strip is hidden in this mode.
    private var browseControls: some View {
        FileBrowseBar(
            isEnabled: canType,
            onInterrupt: { model.send(Data("\u{03}".utf8), to: terminal) },
            onEscape: { model.send(Data("\u{1B}".utf8), to: terminal) },
            onTab: { model.send(Data("\t".utf8), to: terminal) }
        )
    }

    private func toggleBrowsing() {
        withAnimation(Motion.tap) { isBrowsing.toggle() }
        if isBrowsing {
            // Asked on every entry since the folder may have changed; not from an ended shell, where the refusal would land on a browser nobody can reload.
            if canType { model.listDirectory(browsingPath, sessionID: terminal.id) }
        } else {
            model.closePreview()
        }
    }

    private func open(_ entry: RemoteDirectoryEntry) {
        let path = childPath(entry.name, of: browsingPath)
        if entry.isDirectory {
            navigate(to: path)
        } else {
            model.previewFile(path, sessionID: terminal.id)
        }
    }

    /// Runs in the current shell: an SSH session here has one shell, so there is no second to open. The panel already holds the confirmation.
    private func run(_ entry: RemoteDirectoryEntry) {
        let path = childPath(entry.name, of: browsingPath)
        model.send(Data((ShellPath.runCommand(for: path) + "\r").utf8), to: terminal)
        withAnimation(Motion.tap) { isBrowsing = false }
    }

    /// The cd goes in as bytes, not through the command field. `cd --` and quoting because a path is data (a folder named `-P` or `; rm -rf ~`).
    private func navigate(to path: String) {
        model.setBrowsingPath(path, for: terminal.id)
        model.listDirectory(path, sessionID: terminal.id)
        model.send(Data("cd -- \(ShellPath.quoted(path))\r".utf8), to: terminal)
    }

    /// Back to the terminal too, since the field is not on screen while browsing. Quoted so the field holds the form that runs on Return.
    private func reveal(_ path: String) {
        withAnimation(Motion.tap) { isBrowsing = false }
        model.closePreview()
        command = ShellPath.quoted(path)
        inputFocused = true
    }

    // MARK: - Input

    private var input: some View {
        HStack(spacing: 8) {
            InputCapsule {
                TerminalCommandField(
                    text: $command,
                    isFocused: $inputFocused,
                    placeholder: String(localized: "Send a command"),
                    isEnabled: canType,
                    onSubmit: submit
                )
                // A `UITextField` has no intrinsic height, so the frame is here rather than inside the
                // representable, and it is the representable's own number.
                .frame(height: TerminalCommandField.height)

                if inputFocused {
                    TerminalHideKeyboardKey()
                }
            }
            .animation(Motion.tap, value: inputFocused)

            // An empty line sends Return on its own, which is what the deck's Enter key was.
            InputSendButton(
                symbol: command.isEmpty ? "return" : "arrow.up",
                isEnabled: canType,
                label: command.isEmpty ? "Enter" : "Send"
            ) {
                if command.isEmpty { model.send(Data("\r".utf8), to: terminal) } else { submit() }
            }
        }
        .inputBarMargins()
    }

    private func submit() {
        guard canType, !command.isEmpty else { return }
        if TerminalProgram.prefersSmallText(command) {
            textSize = TerminalMetrics.TextSize.tiny.rawValue
        }
        model.send(Data(command.utf8), to: terminal)
        model.send(Data("\r".utf8), to: terminal)
        command = ""
        // Kept up: closing the keyboard after every command makes a terminal on a phone unusable.
        inputFocused = true
    }
}
