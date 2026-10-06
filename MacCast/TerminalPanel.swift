import MacCastKit
import RemoteCore
import SwiftUI

enum TerminalFlowStep: Hashable {
    case terminal(UUID)
    case chat(UUID)
    case folder(TerminalAgent)
    case files
    case terminalFolder
}

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
                            // The picker stays up while the Mac opens the chat, so the way in is one push.
                            model.startAgentChat(agentID: agent.id, directory: directory)
                        }
                    case .files:
                        MacFilesScreen()
                    case .terminalFolder:
                        AgentFolderPicker(title: String(localized: "New terminal"), agentID: "terminal") { directory in
                            AgentFolderHistory.record(directory: directory, agentID: "terminal", macName: model.hostName)
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
            // A shell or chat made while the cover was away was already opened by its maker; do not jump to it.
            model.newTerminalID = nil
            model.newAgentSessionID = nil
        }
        // **The Mac's answer moves the screen, never the tap.** A new terminal or chat has no id until the Mac says so; clear the note so it opens once.
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

private struct TerminalHubScreen: View {
    @Binding var path: [TerminalFlowStep]
    @Environment(SessionModel.self) var model

    @State private var history = AgentHistory.load()
    /// Both kinds behind one alert: two alerts on one screen means one does not present.
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

    private func hubState(_ state: TerminalState) -> HubState? {
        switch state {
        case .running: return .live
        case .attention: return .pending
        case .failed: return .failed
        case .starting, .stopped: return nil
        }
    }

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

    enum HubState {
        case live
        case pending
        case failed
    }

    @ViewBuilder
    private func stateDot(_ state: HubState?) -> some View {
        if let state {
            Circle()
                .fill(tint(for: state))
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
