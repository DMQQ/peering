import MacCastKit
import RemoteCore
import SwiftUI

enum TerminalFlowStep: Hashable {
    case terminal(UUID)
    case chat(UUID)
    case folder(TerminalAgent, String?)
    case files(String?)
    case terminalFolder(String?)
}

/// Where the remote screen's navigation stack is: the hub is the first page, and everything the hub opens is a step above it.
enum RemoteRoute: Hashable {
    case hub
    case step(TerminalFlowStep)
}

/// The hub of terminals and agent chats, and the pages it opens, as pages of the remote screen's own stack so the swipe back works on every one of them.
struct TerminalPanel: View {
    @Environment(SessionModel.self) var model

    @Binding var route: [RemoteRoute]

    var path: [TerminalFlowStep] {
        get {
            route.compactMap {
                if case .step(let step) = $0 { step } else { nil }
            }
        }
        nonmutating set { route = [.hub] + newValue.map(RemoteRoute.step) }
    }

    private var pathBinding: Binding<[TerminalFlowStep]> {
        Binding(get: { path }, set: { path = $0 })
    }

    /// The folder pages were only the way to the new session: back from it lands on the list, not on a folder.
    private func dropFolderPages() {
        path.removeAll {
            switch $0 {
            case .folder, .terminalFolder, .files: true
            default: false
            }
        }
    }

    /// One page per depth, so the swipe back is one level up. A folder already in the stack is returned to rather than stacked again.
    private func openFolder(_ target: String, _ step: (String) -> TerminalFlowStep) {
        let destination = step(target)
        if let index = path.lastIndex(of: destination) {
            path = Array(path[...index])
        } else {
            path.append(destination)
        }
    }

    private func takeBannerRequest() {
        guard let target = InAppBanner.shared.takeOpenRequest() else { return }
        switch target {
        case .chat(let id):
            model.selectedAgentSessionID = id
            path = [.chat(id)]
        case .terminal(let id):
            path = [.terminal(id)]
        case .sshTerminal:
            break
        }
    }

    var body: some View {
        TerminalHubScreen(path: pathBinding)
            .onAppear { takeBannerRequest() }
            .onChange(of: InAppBanner.shared.openRequest) { _, _ in takeBannerRequest() }
            .navigationBarTitleDisplayMode(.inline)
            .toolbarBackground(ColorPalette.backdrop, for: .navigationBar)
            .toolbarBackground(.visible, for: .navigationBar)
            .preferredColorScheme(.dark)
            .onAppear {
                model.refreshTerminals()
                model.refreshAgents()
                model.refreshAgentSessions()
                // A shell or chat made while the hub was away was already opened by its maker; do not jump to it.
                model.newTerminalID = nil
                model.newAgentSessionID = nil
            }
            // **The Mac's answer moves the screen, never the tap.** A new terminal or chat has no id until the Mac says so; clear the note so it opens once.
            .onChange(of: model.newTerminalID) { _, id in
                guard let id else { return }
                model.newTerminalID = nil
                guard pageIsHubOrPicker else { return }
                dropFolderPages()
                path.append(.terminal(id))
            }
            .onChange(of: model.newAgentSessionID) { _, id in
                guard let id else { return }
                model.newAgentSessionID = nil
                guard pageIsHubOrPicker else { return }
                dropFolderPages()
                path.append(.chat(id))
            }
    }

    /// A chat or shell the Mac announces opens only from the list or the picker that asked for it, never over a page being read.
    private var pageIsHubOrPicker: Bool {
        switch path.last {
        case nil, .folder, .terminalFolder: true
        default: false
        }
    }

    @ViewBuilder
    func page(for step: TerminalFlowStep) -> some View {
        switch step {
        case .terminal(let id):
            TerminalScreen(terminalID: id)
        case .chat(let id):
            AgentChatScreen(sessionID: id)
        case .folder(let agent, let directory):
            AgentFolderPicker(
                title: agent.name,
                agentID: agent.id,
                directory: directory,
                open: { openFolder($0) { .folder(agent, $0) } }
            ) { directory in
                // The picker stays up while the Mac opens the chat, so the way in is one push.
                model.startAgentChat(agentID: agent.id, directory: directory)
            }
        case .files(let directory):
            MacFilesScreen(path: directory) { openFolder($0) { .files($0) } }
        case .terminalFolder(let directory):
            AgentFolderPicker(
                title: String(localized: "New terminal"),
                agentID: "terminal",
                directory: directory,
                open: { openFolder($0) { .terminalFolder($0) } }
            ) { directory in
                AgentFolderHistory.record(directory: directory, agentID: "terminal", macName: model.hostName)
                model.createTerminal(inDirectory: directory)
            }
        }
    }
}

private struct TerminalHubScreen: View {
    @Binding var path: [TerminalFlowStep]
    @Environment(SessionModel.self) var model

    @State private var history = AgentHistory.load()
    @State private var selectedAgentID: String?
    @State private var pickerOpen = false
    @State private var choosing: String?
    @State private var tab: HubTab = HubTab(rawValue: UserDefaults.standard.string(forKey: "Peering.hubTab") ?? "") ?? .agents
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
        // Both pages stay built: tearing one down and building the other on each switch was the lag. Only opacity changes.
        ZStack {
            page(.agents) {
                pageHeading(
                    "Agents",
                    detail: model.agentCards.contains { $0.isLive }
                        ? String(localized: "\(model.agentCards.filter(\.isLive).count) open on your Mac")
                        : String(localized: "Chat with a coding agent on your Mac")
                )
                chatsSection
                agentsNotice
                historySection
            }
            page(.terminals) {
                pageHeading(
                    "Terminals",
                    detail: model.hostName.map { String(localized: "Shells running on \($0)") }
                        ?? String(localized: "Shells running on your Mac")
                )
                terminalsSection
            }
        }
        .animation(.easeOut(duration: 0.12), value: tab)
        .onChange(of: tab) { _, tab in
            UserDefaults.standard.set(tab.rawValue, forKey: "Peering.hubTab")
            Analytics.panelOpened(tab == .agents ? .agents : .terminals)
        }
        .scrollBounceBehavior(.basedOnSize)
        .toolbar { tabsItem }
        .safeAreaInset(edge: .bottom, spacing: 0) {
            if dockIsShown {
                Group {
                    if tab == .agents { agentDock } else { terminalDock }
                }
            }
        }
        .animation(Motion.settle, value: dockIsShown)
        .overlay { agentPicker }
        .onChange(of: tab) { _, _ in pickerOpen = false }
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
        VStack(alignment: .leading, spacing: 12) {
            if model.terminalCards.isEmpty {
                TerminalEmptyState(canCreate: model.canOpenAnotherShellFromCards) {
                    path.append(.terminalFolder(nil))
                }
            } else {
                ForEach(Array(model.terminalCards.enumerated()), id: \.element.id) { index, terminal in
                    terminalRow(terminal, index: index)
                }
                newTerminalRow
            }
        }
    }

    private var newTerminalRow: some View {
        PlanLocked(
            capability: .shellTabs,
            title: String(localized: "New terminal"),
            diameter: 30,
            isIncluded: model.canOpenAnotherShellFromCards
        ) {
            Button { path.append(.terminalFolder(nil)) } label: {
                HStack(spacing: 8) {
                    Image(systemName: "plus").font(.system(size: 13, weight: .bold))
                    Text("New terminal").font(.system(size: 14.5, weight: .semibold))
                }
                .foregroundStyle(.white.opacity(0.7))
                .frame(maxWidth: .infinity)
                .frame(height: 52)
                .overlay {
                    RoundedRectangle(cornerRadius: 20, style: .continuous)
                        .strokeBorder(.white.opacity(0.2), style: StrokeStyle(lineWidth: 1, dash: [5, 4]))
                }
                .contentShape(RoundedRectangle(cornerRadius: 20, style: .continuous))
            }
            .buttonStyle(.plain)
            .accessibilityLabel("New terminal")
        }
    }

    private func terminalRow(_ terminal: TerminalCardDigest, index: Int) -> some View {
        Button {
            model.selectTerminal(terminal.id)
            path.append(.terminal(terminal.id))
        } label: {
            TerminalWindowCard(terminal: terminal, index: index, host: model.hostName)
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

    // MARK: - Chats

    @ViewBuilder
    private var chatsSection: some View {
        if !model.agentCards.isEmpty {
            VStack(alignment: .leading, spacing: 10) {
                Controls.sectionLabel("Chats", systemImage: "bubble.left.and.text.bubble.right")
                VStack(spacing: 10) {
                    ForEach(Array(model.agentCards.enumerated()), id: \.element.id) { index, session in
                        chatRow(session, index: index)
                    }
                }
            }
            .padding(.top, 20)
        }
    }

    private func chatBadge(_ state: AgentSessionState) -> SessionBadge {
        switch state {
        case .idle: return .ready
        case .working: return .working
        case .awaitingApproval: return .needsYou
        case .exited: return .ended
        case .failed: return .failed
        }
    }

    private func chatRow(_ session: AgentCardDigest, index: Int) -> some View {
        let agent = TerminalAgent.all.first { $0.id == session.agentID }
        let folder = (session.directory as NSString).lastPathComponent
        return Button {
            model.selectedAgentSessionID = session.id
            path.append(.chat(session.id))
        } label: {
            SessionCard(
                symbol: agent?.symbol ?? "sparkles",
                title: session.title,
                badge: chatBadge(session.state),
                index: index,
                folder: folder.isEmpty ? nil : folder,
                preview: session.preview,
                activity: session.activity,
                plan: session.plan
            ) {
                // The title usually starts with the agent's name already: saying it twice wrapped the row.
                if !session.title.localizedCaseInsensitiveContains(agent?.name ?? session.agentID) {
                    Text(verbatim: agent?.name ?? session.agentID)
                }
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

    // MARK: - Agents

    /// Only what the page cannot be silent about: no agent found, or nothing started yet. The agent itself is chosen in the bar.
    @ViewBuilder
    private var agentsNotice: some View {
        if !model.isAwaitingAgentList {
            if model.availableAgents.isEmpty {
                HStack(spacing: 12) {
                    IconTile(symbol: "sparkles")
                    Text("No supported agents were found on this Mac. Install one and it will show up here.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                    Spacer(minLength: 0)
                }
                .padding(.top, 20)
            } else if model.agentCards.isEmpty {
                AgentEmptyState()
                    .padding(.top, 20)
            }
        }
    }

    /// Nothing is chosen until the person chooses, unless there is only one agent to choose.
    private var selectedAgent: TerminalAgent? {
        model.availableAgents.first { $0.id == selectedAgentID }
            ?? (model.availableAgents.count == 1 ? model.availableAgents.first : nil)
    }

    private static let pickerSpring = Animation.spring(response: 0.45, dampingFraction: 0.78)

    /// The agents as a panel rising out of the bar, which a menu is too small to be. Always built, so the way out animates as well as the way in: a parent removed with its children never plays their transitions.
    private var agentPicker: some View {
        ZStack(alignment: .bottom) {
            if pickerOpen {
                Color.black.opacity(0.55)
                    .ignoresSafeArea()
                    .onTapGesture { closePicker() }
                    .transition(.opacity)
            }
            // The column stays while the cards come and go inside it: a card's own transition only plays when its parent is not the thing being removed.
            VStack(spacing: 10) {
                ForEach(Array(model.availableAgents.enumerated()), id: \.element.id) { index, agent in
                    if pickerOpen {
                        pickerCard(agent, index: index)
                            .transition(Self.cardTransition(index: index, of: model.availableAgents.count))
                    }
                }
            }
            .padding(.horizontal, 16)
            .padding(.bottom, 84)
        }
        .allowsHitTesting(pickerOpen)
    }

    /// Cards fan up out of the bar nearest first and fold back into it farthest first, so the panel reads as one thing opening and closing from the button.
    private static func cardTransition(index: Int, of count: Int) -> AnyTransition {
        let fromBar = Double(count - 1 - index)
        return .asymmetric(
            insertion: AnyTransition(RisingCard())
                .animation(.spring(response: 0.5, dampingFraction: 0.74).delay(0.04 * fromBar)),
            removal: AnyTransition(RisingCard())
                .animation(.spring(response: 0.34, dampingFraction: 0.9).delay(0.035 * Double(index)))
        )
    }

    private func closePicker() {
        withAnimation(Self.pickerSpring) { pickerOpen = false; choosing = nil }
    }

    private func pickerCard(_ agent: TerminalAgent, index: Int) -> some View {
        let chats = model.agentCards.filter { $0.agentID == agent.id && $0.isLive }
        let status = AgentCardStatus(
            working: chats.filter { $0.state == .working }.count,
            needsYou: chats.filter { $0.state == .awaitingApproval }.count,
            chats: chats.count,
            lastUsed: lastUsedLine(agent)
        )
        return AgentHubCard(
            agent: agent,
            status: status,
            index: index,
            isSelected: selectedAgentID == agent.id,
            select: {
                selectedAgentID = agent.id
                withAnimation(.spring(response: 0.3, dampingFraction: 0.55)) { choosing = agent.id }
                Task {
                    try? await Task.sleep(for: .milliseconds(240))
                    closePicker()
                }
            }
        )
        .scaleEffect(choosing == agent.id ? 1.045 : 1)
        .opacity(choosing != nil && choosing != agent.id ? 0.4 : 1)
        .background(ColorPalette.backdrop, in: RoundedRectangle(cornerRadius: 22, style: .continuous))
    }

    private func chatCapable(_ agent: TerminalAgent) -> Bool {
        agent.supportsChat && model.activeSession?.hostSupportsAgentChat == true
            && model.activeSession?.hostChatAgents.contains(agent.id) == true
    }

    private func pageHeading(_ title: LocalizedStringKey, detail: String) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(title)
                .font(DisplayFont.display(34))
                .tracking(-0.8)
                .foregroundStyle(ColorPalette.ink)
            Text(verbatim: detail)
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .lineLimit(1)
        }
        .padding(.horizontal, 4)
        .padding(.top, 4)
        .padding(.bottom, 6)
    }

    private func page<Content: View>(_ which: HubTab, @ViewBuilder content: () -> Content) -> some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 0) {
                content()
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, 16)
            .padding(.top, 12)
            .padding(.bottom, 28)
        }
        .scrollBounceBehavior(.basedOnSize)
        .opacity(tab == which ? 1 : 0)
        .environment(\.animationsPaused, tab != which)
        .allowsHitTesting(tab == which)
        .accessibilityHidden(tab != which)
    }

    private var tabSwitcher: some View {
        HubTabs(
            selection: $tab,
            terminalCount: model.terminalCards.count,
            agentCount: model.agentCards.filter(\.isLive).count,
            agentsBusy: model.agentCards.contains { $0.state == .working },
            compact: true
        )
        .frame(width: 296)
    }

    /// Trailing rather than centred: the bar is empty but for the close button, and a centred item is limited to what the larger side leaves.
    /// Without the bar's own capsule behind it: that one adds its own padding round the item, so the gap beside the selected pill was wider than the one above it, and ours sat inside it as a second glass.
    @ToolbarContentBuilder
    private var tabsItem: some ToolbarContent {
        if #available(iOS 26.0, *) {
            ToolbarItem(placement: .topBarTrailing) { tabSwitcher }
                .sharedBackgroundVisibility(.hidden)
        } else {
            ToolbarItem(placement: .topBarTrailing) { tabSwitcher }
        }
    }

    private var dockIsShown: Bool {
        tab == .terminals || !model.availableAgents.isEmpty || model.hostSupportsFileBrowser
    }

    private var terminalDock: some View {
        TerminalDock(offersFiles: model.hostSupportsFileBrowser, files: { path.append(.files(nil)) }) { button in
            PlanLocked(
                capability: .shellTabs,
                title: String(localized: "New terminal"),
                diameter: 26,
                isIncluded: model.canOpenAnotherShell
            ) { button }
        } newTerminal: {
            path.append(.terminalFolder(nil))
        }
    }

    private var agentDock: some View {
        AgentDock(
            agent: selectedAgent,
            agentCount: model.availableAgents.count,
            openPicker: { withAnimation(Self.pickerSpring) { pickerOpen = true } },
            canChat: selectedAgent.map(chatCapable) ?? false,
            offersFiles: model.hostSupportsFileBrowser,
            files: { path.append(.files(nil)) },
            chat: { if let agent = selectedAgent { path.append(.folder(agent, nil)) } },
            terminal: { if let agent = selectedAgent { start(agent) } }
        )
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
                HistoryCard(entries: history.prefix(20).map(historyEntry))
            }
            .padding(.top, 20)
        }
    }

    private func historyEntry(_ entry: AgentLaunch) -> HistoryCard.Entry {
        let agent = TerminalAgent.all.first { $0.id == entry.agentID }
        let live = entry.terminalID.flatMap { id in
            model.terminalCards.first { $0.id == id && $0.isRunning }?.id
        }
        return HistoryCard.Entry(
            id: entry.id,
            symbol: agent?.symbol ?? "sparkles",
            title: agent?.name ?? entry.agentID,
            detail: entry.macName,
            date: entry.date,
            isLive: live != nil,
            isEnabled: agent != nil || live != nil
        ) {
            if let live {
                model.selectTerminal(live)
                path.append(.terminal(live))
            } else if let agent {
                start(agent, restarting: entry)
            }
        }
    }

    // MARK: - Renaming and ending

    private func beginRename(_ terminal: TerminalCardDigest) {
        renameText = terminal.name
        renaming = .terminal(terminal.id)
    }

    private func beginRename(_ session: AgentCardDigest) {
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
        case .terminal(let id): return model.terminalCards.first { $0.id == id }?.name ?? ""
        case .chat(let id): return model.agentCards.first { $0.id == id }?.title ?? ""
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

private struct RisingCard: Transition {
    func body(content: Content, phase: TransitionPhase) -> some View {
        content
            .scaleEffect(phase.isIdentity ? 1 : 0.82, anchor: .bottom)
            .offset(y: phase.isIdentity ? 0 : 56)
            .blur(radius: phase.isIdentity ? 0 : 8)
            .opacity(phase.isIdentity ? 1 : 0)
    }
}
