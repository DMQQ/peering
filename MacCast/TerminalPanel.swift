import MacCastKit
import RemoteCore
import SwiftUI

/// One step of the Mac terminals cover's own navigation.
///
/// Everything the cover holds is a screen of this one stack: the hub, a shell, a chat, and the
/// folder a chat is started in. Nothing is presented over anything else, so a start or a close
/// never moves the screen under a thumb, and the way back from any of them is the same back.
enum TerminalFlowStep: Hashable {
    case terminal(UUID)
    case chat(UUID)
    case folder(TerminalAgent)
    /// The Mac's folders, browsed with no shell behind them.
    case files
    /// Where a new shell should open, asked before it is made.
    case terminalFolder
}

/// The Mac terminals cover: a hub of everything running on the Mac, and the screens it opens.
///
/// A full-screen cover rather than a sheet, and the hub is the answer to "what is over there and
/// how do I start more": the shells this phone holds, the agent chats, the agents installed, and
/// what has been started before. A tap pushes the thing itself.
struct TerminalPanel: View {
    @Environment(SessionModel.self) var model
    @Environment(\.dismiss) var dismiss

    @State var path: [TerminalFlowStep] = []

    var body: some View {
        NavigationStack(path: $path) {
            TerminalHubScreen(path: $path)
                .navigationTitle("Mac terminals")
                .navigationBarTitleDisplayMode(.inline)
                .toolbarBackground(ColorPalette.backdrop, for: .navigationBar)
                .toolbarBackground(.visible, for: .navigationBar)
                .toolbar {
                    ToolbarItem(placement: .cancellationAction) {
                        Button("Done") { dismiss() }
                    }
                }
                .navigationDestination(for: TerminalFlowStep.self) { step in
                    switch step {
                    case .terminal(let id):
                        TerminalScreen(terminalID: id)
                    case .chat(let id):
                        AgentChatScreen(sessionID: id)
                    case .folder(let agent):
                        AgentFolderPicker(title: agent.name, agentID: agent.id) { directory in
                            // The picker stays up while the Mac opens it: the chat arrives as a session
                            // and is pushed onto it, so the way in is one push. Popping to the hub
                            // first and pushing from there read as two screens.
                            model.startAgentChat(agentID: agent.id, directory: directory)
                        }
                    case .files:
                        MacFilesScreen()
                    case .terminalFolder:
                        AgentFolderPicker(title: String(localized: "New terminal"), agentID: "terminal") { directory in
                            AgentFolderHistory.record(directory: directory, agentID: "terminal", macName: model.hostName)
                            // Stays up for the same reason as the chat picker above.
                            model.createTerminal(inDirectory: directory)
                        }
                    }
                }
        }
        .preferredColorScheme(.dark)
        .onAppear {
            model.refreshTerminals()
            model.refreshAgents()
            model.refreshAgentSessions()
            // A shell or a chat made while this cover was away has already been opened by whoever
            // made it, so its arrival is not one to jump at now.
            model.newTerminalID = nil
            model.newAgentSessionID = nil
        }
        // **The Mac's answer moves the screen, never the tap.** A terminal and a chat have no id
        // until the Mac says it made one, so the screen that asked cannot push at the tap; it waits
        // here, takes the arrival, and clears the note so the same one is opened only once.
        .onChange(of: model.newTerminalID) { _, id in
            guard let id else { return }
            model.newTerminalID = nil
            path.append(.terminal(id))
        }
        .onChange(of: model.newAgentSessionID) { _, id in
            guard let id else { return }
            model.newAgentSessionID = nil
            switch path.last {
            case .folder, .terminalFolder:
                path.append(.chat(id))
            default:
                path = [.chat(id)]
            }
        }
    }
}

/// What is running on the Mac, and the ways to start more: the hub's own screen.
private struct TerminalHubScreen: View {
    @Binding var path: [TerminalFlowStep]
    @Environment(SessionModel.self) var model

    @State private var history = AgentHistory.load()
    /// What a close was asked for and not yet confirmed. Both kinds behind one alert: two alerts
    /// on one screen is one alert that does not present.
    @State private var pendingEnd: PendingEnd?
    @State private var renaming: Renaming?
    @State private var renameText = ""

    private enum PendingEnd: Equatable {
        case terminal(UUID)
        case chat(UUID)
    }

    private enum Renaming: Equatable {
        case terminal(UUID)
        case chat(UUID)
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 0) {
                terminalsSection
                filesSection
                chatsSection
                agentsSection
                historySection
            }
            .padding(.horizontal, 16)
            .padding(.top, 18)
            .padding(.bottom, 28)
        }
        .scrollBounceBehavior(.basedOnSize)
        .background(ColorPalette.backdrop)
        .terminalEndPrompt(
            name: pendingEndName,
            detail: pendingEndDetail,
            isPresented: Binding(
                get: { pendingEnd != nil },
                set: { if !$0 { pendingEnd = nil } }
            ),
            onEnd: endPending
        )
        .alert("Rename", isPresented: Binding(
            get: { renaming != nil },
            set: { if !$0 { renaming = nil } }
        )) {
            TextField("Name", text: $renameText)
            Button("Cancel", role: .cancel) { renaming = nil }
            Button("Save") { commitRename() }
        }
        .onAppear { model.refreshAgents() }
    }

    // MARK: - Terminals

    private var terminalsSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            Controls.sectionLabel("Terminals", systemImage: "terminal")
            VStack(spacing: 10) {
                if model.terminals.isEmpty {
                    emptyTerminals
                } else {
                    ForEach(model.terminals) { terminal in
                        terminalRow(terminal)
                    }
                    newTerminalRow
                }
            }
        }
    }

    /// Nothing running, drawn as a card that offers the way out of that rather than as a line of
    /// grey text: on a Mac with nothing open this card holds the screen's one action, and it is
    /// the first thing a new user sees.
    private var emptyTerminals: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 12) {
                IconTile(symbol: "terminal")
                VStack(alignment: .leading, spacing: 3) {
                    Text("No terminals")
                        .font(.subheadline.weight(.semibold))
                        .foregroundStyle(ColorPalette.ink)
                    Text("Runs on your Mac, not here. It keeps going when you disconnect.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                Spacer(minLength: 0)
            }
            PlanLocked(
                capability: .shellTabs,
                title: String(localized: "New terminal"),
                diameter: 42,
                isIncluded: model.canOpenAnotherShell
            ) {
                Button { path.append(.terminalFolder) } label: {
                    HStack(spacing: 7) {
                        Image(systemName: "terminal")
                            .font(.system(size: 13, weight: .semibold))
                        Text("New terminal")
                            .font(.system(size: 15, weight: .semibold))
                    }
                    .foregroundStyle(ColorPalette.onInk)
                    .frame(maxWidth: .infinity)
                    .frame(height: 44)
                    .background(ColorPalette.ink, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
                    .contentShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
                }
                .buttonStyle(.plain)
                .accessibilityLabel("New terminal")
            }
        }
    }

    /// The one row that makes something rather than opening it. Gated by the plan the way the
    /// toolbar's plus used to be: the first shell is free on every plan, so the question is only
    /// "paid, or is this the first one".
    private var newTerminalRow: some View {
        PlanLocked(
            capability: .shellTabs,
            title: String(localized: "New terminal"),
            diameter: 30,
            isIncluded: model.canOpenAnotherShell
        ) {
            Button { path.append(.terminalFolder) } label: {
                hubRow(symbol: "plus", title: String(localized: "New terminal"), detail: nil) {
                    chevron
                }
            }
            .buttonStyle(.plain)
            .accessibilityLabel("New terminal")
        }
    }

    // MARK: - Files

    /// The Mac's own folders, without opening a shell to reach them.
    ///
    /// Its own section rather than a row among the terminals, because it is not one: what the two
    /// share is a way of looking at the Mac, and the row is here so that looking at files does not
    /// require having a shell open first — which was the only way in before. A system toolbar was
    /// tried for these actions and taken back out: an icon in a bottom bar had no word with it, and
    /// the whole complaint this screen answers is which control opens a terminal.
    @ViewBuilder
    private var filesSection: some View {
        if model.hostSupportsFileBrowser {
            VStack(alignment: .leading, spacing: 10) {
                Controls.sectionLabel("Files", systemImage: "folder")
                Button { path.append(.files) } label: {
                    hubRow(
                        symbol: "folder",
                        title: String(localized: "This Mac's files"),
                        detail: String(localized: "Browse, upload and download")
                    ) {
                        chevron
                    }
                }
                .buttonStyle(.plain)
                .accessibilityIdentifier("files-row")
            }
            .padding(.top, 20)
        }
    }

    private func terminalRow(_ terminal: RemoteTerminal) -> some View {
        Button {
            model.selectTerminal(terminal.id)
            path.append(.terminal(terminal.id))
        } label: {
            hubRowLive(
                symbol: "terminal",
                title: terminal.name,
                state: hubState(terminal.state)
            ) {
                terminalDetail(terminal)
            } control: {
                chevron
            }
        }
        .buttonStyle(.plain)
        .contextMenu {
            Button("Rename", systemImage: "character.cursor.ibeam") { beginRename(terminal) }
                .menuInk()
            Button("End", systemImage: "xmark", role: .destructive) { pendingEnd = .terminal(terminal.id) }
                .menuDanger()
        }
        .accessibilityIdentifier("terminal-row")
    }

    /// What the shell's dot says, which is only ever about now: a shell that has ended is not a
    /// state worth a colour, and a shell still coming up has nothing to report yet.
    private func hubState(_ state: TerminalState) -> HubState? {
        switch state {
        case .running: return .live
        case .attention: return .pending
        case .failed: return .failed
        case .starting, .stopped: return nil
        }
    }

    /// What the row's second line says about the shell, in the app's own colours for the two
    /// states that want the user: something waiting, and something broken.
    ///
    /// A shell that is up says for how long, which is a live reading rather than a fact: the
    /// timeline re-draws it once a minute, so a hub left open does not go on claiming "just now".
    @ViewBuilder
    private func terminalDetail(_ terminal: RemoteTerminal) -> some View {
        let (text, tint) = terminalState(detail: terminal)
        TimelineView(.periodic(from: .now, by: 60)) { _ in
            Text(tint == nil && terminal.isRunning ? text + runningSuffix(terminal) : text)
                .font(.caption)
                .foregroundStyle(tint ?? .secondary)
                .lineLimit(1)
                .truncationMode(.middle)
        }
    }

    /// " · 12m" for a shell that was opened a while ago, and nothing for one that just was.
    private func runningSuffix(_ terminal: RemoteTerminal) -> String {
        guard let createdAt = terminal.createdAt else { return "" }
        let seconds = Date.now.timeIntervalSince(createdAt)
        guard seconds >= 60 else { return "" }
        let minutes = Int(seconds / 60)
        if minutes < 60 { return " · \(minutes)m" }
        return " · \(minutes / 60)h \(minutes % 60)m"
    }

    private func terminalState(detail terminal: RemoteTerminal) -> (String, Color?) {
        switch terminal.state {
        case .starting:
            return (String(localized: "Starting…"), nil)
        case .running:
            return (String(localized: "Running on your Mac"), nil)
        case .attention(let kind):
            return kind == .password
                ? (String(localized: "Waiting for your password"), ColorPalette.caution)
                : (String(localized: "Waiting for you to confirm"), ColorPalette.caution)
        case .failed(let message):
            return (message, ColorPalette.danger)
        case .stopped:
            return (String(localized: "Exited"), nil)
        }
    }

    // MARK: - Chats

    @ViewBuilder
    private var chatsSection: some View {
        if !model.agentSessions.isEmpty {
            VStack(alignment: .leading, spacing: 10) {
                Controls.sectionLabel("Chats", systemImage: "bubble.left.and.text.bubble.right")
                VStack(spacing: 10) {
                    ForEach(model.agentSessions) { session in
                        chatRow(session)
                    }
                }
            }
            .padding(.top, 20)
        }
    }

    private func chatRow(_ session: RemoteAgentSession) -> some View {
        let (detail, tint) = chatDetail(session)
        let symbol = TerminalAgent.all.first { $0.id == session.agentID }?.symbol ?? "sparkles"
        return Button {
            model.selectedAgentSessionID = session.id
            path.append(.chat(session.id))
        } label: {
            hubRow(symbol: symbol, title: session.title, detail: detail, detailTint: tint, state: hubState(session.state)) {
                chevron
            }
        }
        .buttonStyle(.plain)
        .contextMenu {
            // Continuing a chat whose CLI has gone: a new conversation with the same agent in the
            // same folder, which is as close to picking it up as either CLI offers.
            Button("New chat here", systemImage: "plus.bubble") {
                model.startAgentChat(agentID: session.agentID, directory: session.directory)
            }
            .menuInk()
            Button("Rename", systemImage: "character.cursor.ibeam") { beginRename(session) }
                .menuInk()
            Button("Close", systemImage: "xmark", role: .destructive) { pendingEnd = .chat(session.id) }
                .menuDanger()
        }
        .accessibilityIdentifier("chat-row")
    }

    private func hubState(_ state: AgentSessionState) -> HubState? {
        switch state {
        case .working: return .live
        case .awaitingApproval: return .pending
        case .failed: return .failed
        case .idle, .exited: return nil
        }
    }

    private func chatDetail(_ session: RemoteAgentSession) -> (String, Color?) {
        switch session.state {
        case .idle:
            return (String(localized: "Ready"), nil)
        case .working:
            return (String(localized: "Working…"), nil)
        case .awaitingApproval:
            return (String(localized: "Waiting on you"), ColorPalette.caution)
        case .exited:
            return (String(localized: "Ended"), nil)
        case .failed:
            return (String(localized: "Failed"), ColorPalette.danger)
        }
    }

    // MARK: - Agents

    private var agentsSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            Controls.sectionLabel("Agents", systemImage: "sparkles")
            VStack(spacing: 10) {
                if model.isAwaitingAgentList {
                    EmptyView()
                } else if model.availableAgents.isEmpty {
                    HStack(spacing: 12) {
                        IconTile(symbol: "sparkles")
                        Text("No supported agents were found on this Mac. Install one and it will show up here.")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                        Spacer(minLength: 0)
                    }
                } else {
                    ForEach(model.availableAgents) { agent in
                        agentRow(agent)
                    }
                }
                // The one thing the rows cannot say by themselves: two controls, both of which
                // start something on the Mac, and nothing in the words alone that says where each
                // one puts you. Said once under them rather than on every row.
                if !model.availableAgents.isEmpty {
                    Text("Chat is this app's own screen for the agent, where its questions arrive as buttons. Terminal opens the same agent in a shell on your Mac.")
                        .font(.caption)
                        .foregroundStyle(.tertiary)
                        .fixedSize(horizontal: false, vertical: true)
                        .padding(.horizontal, 4)
                        .padding(.top, 2)
                }
            }
        }
        .padding(.top, 20)
    }

    private func agentRow(_ agent: TerminalAgent) -> some View {
        let canChat = agent.supportsChat && model.activeSession?.hostSupportsAgentChat == true
            && model.activeSession?.hostChatAgents.contains(agent.id) == true
        return hubRow(symbol: agent.symbol, title: agent.name, detail: lastUsedLine(agent)) {
        } footer: {
            if canChat {
                HStack(spacing: 0) {
                    PlanLocked(
                        capability: .agentChat,
                        title: String(localized: "Chat with \(agent.name)"),
                        diameter: 26,
                        isIncluded: model.canOpenAgentChat
                    ) {
                        Button { path.append(.folder(agent)) } label: {
                            splitSegment("Chat", symbol: "bubble.left.and.text.bubble.right")
                                .frame(maxWidth: .infinity)
                        }
                        .buttonStyle(.plain)
                        .accessibilityLabel(Text("Chat with \(agent.name)"))
                    }
                    Rectangle().fill(.white.opacity(0.3)).frame(width: 1, height: 18)
                    Button { start(agent) } label: {
                        splitSegment("Terminal", symbol: "terminal")
                            .padding(.horizontal, 6)
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel(Text("Start \(agent.name)"))
                }
                .frame(height: 34)
                .overlay(Capsule().strokeBorder(.white.opacity(0.3)))
            } else {
                Button { start(agent) } label: {
                    splitSegment("Terminal", symbol: "terminal")
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.plain)
                .accessibilityLabel(Text("Start \(agent.name)"))
                .frame(height: 34)
                .overlay(Capsule().strokeBorder(.white.opacity(0.3)))
            }
        }
    }

    /// One half of the Chat | Terminal capsule: the capsule is the single control, so a half draws
    /// no outline of its own.
    private func splitSegment(_ title: LocalizedStringKey, symbol: String) -> some View {
        HStack(spacing: 6) {
            Image(systemName: symbol).font(.system(size: 12, weight: .semibold))
            Text(title).font(.system(size: 14, weight: .semibold))
        }
        .foregroundStyle(.white)
        .padding(.horizontal, 10)
        .frame(height: 34)
        .contentShape(Rectangle())
    }

    /// Starts a CLI agent, and moves to the shell it landed in.
    ///
    /// Which shell that is decides how the screen gets there: a new one arrives as a session and
    /// the cover opens it, while on a plan that runs a single shell the command goes into the one
    /// in hand, so the push happens here and names it.
    private func start(_ agent: TerminalAgent, restarting entry: AgentLaunch? = nil) {
        if !model.canOpenAnotherShell, let target = model.runningShellTargetID {
            model.launchAgent(agent, restarting: entry)
            path.append(.terminal(target))
        } else {
            model.launchAgent(agent, restarting: entry)
        }
        history = AgentHistory.load()
    }

    private func lastUsedLine(_ agent: TerminalAgent) -> String {
        guard let date = AgentHistory.lastUsed(agent, in: history) else {
            return String(localized: "Never used")
        }
        return String(localized: "Last used \(date.formatted(.relative(presentation: .named)))")
    }

    // MARK: - History

    @ViewBuilder
    private var historySection: some View {
        if !history.isEmpty {
            VStack(alignment: .leading, spacing: 10) {
                HStack {
                    Controls.sectionLabel("History", systemImage: "clock.arrow.circlepath")
                    Spacer(minLength: 8)
                    Button("Clear") {
                        AgentHistory.clear()
                        history = []
                    }
                    .font(.caption.weight(.medium))
                    .foregroundStyle(.secondary)
                }
                VStack(spacing: 10) {
                    ForEach(Array(history.prefix(20)), id: \.id) { entry in
                        historyRow(entry)
                    }
                }
            }
            .padding(.top, 20)
        }
    }

    /// One row of the history, which goes somewhere rather than being a line of text.
    ///
    /// The shell the launch opened, when it is still there — that is "continue" for a CLI session,
    /// and it is what the row is for. A shell that has gone means the agent starts again, which is
    /// the same thing the Start button on its own row does, so the row is never a dead tap.
    private func historyRow(_ entry: AgentLaunch) -> some View {
        let agent = TerminalAgent.all.first { $0.id == entry.agentID }
        let live = entry.terminalID.flatMap { id in
            model.terminals.first { $0.id == id && $0.isRunning }?.id
        }

        return Button {
            if let live {
                model.selectTerminal(live)
                path.append(.terminal(live))
            } else if let agent {
                start(agent, restarting: entry)
            }
        } label: {
            hubRow(
                symbol: agent?.symbol ?? "sparkles",
                title: agent?.name ?? entry.agentID,
                detail: entry.macName
            ) {
                HStack(spacing: 6) {
                    Text(live != nil
                        ? String(localized: "Open")
                        : entry.date.formatted(.relative(presentation: .named)))
                        .font(.caption)
                        .foregroundStyle(live != nil ? ColorPalette.ink : .secondary)
                    chevron
                }
            }
        }
        .buttonStyle(.plain)
        .disabled(agent == nil && live == nil)
        .accessibilityLabel(live != nil
            ? Text("Open the running \(agent?.name ?? entry.agentID)")
            : Text("Start \(agent?.name ?? entry.agentID) again"))
    }

    // MARK: - Rows

    /// The same row for a line that draws itself, which is the one row whose second line is a live
    /// reading rather than a sentence: a shell says how long it has been up, and that changes while
    /// the screen is open.
    private func hubRowLive<Control: View, Detail: View>(
        symbol: String,
        title: String,
        state: HubState? = nil,
        @ViewBuilder detail: () -> Detail,
        @ViewBuilder control: () -> Control
    ) -> some View {
        hubLayout(symbol: symbol, title: title, state: state) {
            detail()
        } control: {
            control()
        }
    }

    /// One line of the hub: the tile, the name, the sentence under it, and whatever the row's own
    /// action is. Everything here is drawn this way, so a shell, a chat and an agent read as three
    /// of one thing rather than three designs.
    ///
    /// A filled row with no card around it, which the user chose: the rows carry the app's one
    /// filled surface and an outline around them was a second edge saying nothing.
    private func hubRow<Control: View>(
        symbol: String,
        title: String,
        detail: String?,
        detailTint: Color? = nil,
        state: HubState? = nil,
        @ViewBuilder control: () -> Control,
        @ViewBuilder footer: () -> some View = { EmptyView() }
    ) -> some View {
        hubLayout(symbol: symbol, title: title, state: state) {
            if let detail, !detail.isEmpty {
                Text(detail)
                    .font(.caption)
                    .foregroundStyle(detailTint ?? .secondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
            }
        } control: {
            control()
        } footer: {
            footer()
        }
    }

    private func hubLayout<Control: View, Detail: View>(
        symbol: String,
        title: String,
        state: HubState?,
        @ViewBuilder detail: () -> Detail,
        @ViewBuilder control: () -> Control,
        @ViewBuilder footer: () -> some View = { EmptyView() }
    ) -> some View {
        VStack(spacing: 10) {
        HStack(spacing: 12) {
            IconTile(symbol: symbol)
                .overlay(alignment: .bottomTrailing) { stateDot(state) }
            VStack(alignment: .leading, spacing: 3) {
                Text(verbatim: title)
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(ColorPalette.ink)
                    .lineLimit(1)
                    .truncationMode(.middle)
                detail()
            }
            Spacer(minLength: 10)
            control()
        }
        footer()
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 9)
        .frame(maxWidth: .infinity, alignment: .leading)
        .rowSurface()
        .contentShape(Rectangle())
    }

    /// The one place colour is spent on this screen, and it is a measurement rather than an
    /// ornament: what is happening right now, in the dot language the session tabs and the Lock
    /// Screen card already use. A hub of identical grey rows is a page where nothing can be found
    /// at a glance — and these disappear entirely when everything is quiet.
    enum HubState {
        /// Something is running.
        case live
        /// Something is waiting on the user.
        case pending
        /// Something ended badly.
        case failed
    }

    @ViewBuilder
    private func stateDot(_ state: HubState?) -> some View {
        if let state {
            Circle()
                .fill(tint(for: state))
                // Ringed in the page's own colour, which is what makes the dot read as sitting on
                // the tile's corner rather than as part of its glyph.
                .overlay(Circle().strokeBorder(ColorPalette.backdrop, lineWidth: 2))
                .frame(width: 11, height: 11)
                .offset(x: 2, y: 2)
        }
    }

    private func tint(for state: HubState) -> Color {
        switch state {
        case .live: return .green
        case .pending: return ColorPalette.caution
        case .failed: return ColorPalette.danger
        }
    }

    private var chevron: some View {
        Image(systemName: "chevron.right")
            .font(.caption.weight(.semibold))
            .foregroundStyle(.tertiary)
    }

    // MARK: - Renaming and ending

    private func beginRename(_ terminal: RemoteTerminal) {
        renameText = terminal.name
        renaming = .terminal(terminal.id)
    }

    private func beginRename(_ session: RemoteAgentSession) {
        renameText = session.title
        renaming = .chat(session.id)
    }

    private func commitRename() {
        guard let renaming else { return }
        let name = renameText.trimmingCharacters(in: .whitespacesAndNewlines)
        switch renaming {
        case .terminal(let id): model.renameTerminal(id, to: name)
        case .chat(let id): model.renameAgentSession(id, to: name)
        }
        self.renaming = nil
    }

    private var pendingEndName: String {
        switch pendingEnd {
        case .terminal(let id): return model.terminals.first { $0.id == id }?.name ?? ""
        case .chat(let id): return model.agentSessions.first { $0.id == id }?.title ?? ""
        case nil: return ""
        }
    }

    private var pendingEndDetail: String {
        switch pendingEnd {
        case .terminal:
            return String(localized: "The shell running in it stops. Your Mac and the rest of the terminals are left alone.")
        case .chat:
            return String(localized: "The agent stops working on your Mac. The Mac and the rest of the chats are left alone.")
        case nil:
            return ""
        }
    }

    private func endPending() {
        switch pendingEnd {
        case .terminal(let id): model.closeTerminal(id)
        case .chat(let id): model.closeAgentSession(id)
        case nil: break
        }
        pendingEnd = nil
    }
}
