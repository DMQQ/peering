import MacCastKit
import RemoteCore
import SwiftUI

extension TerminalHubScreen {
    /// Only what the page cannot be silent about: no agent found, or nothing started yet. The agent itself is chosen in the bar.
    @ViewBuilder
    var agentsNotice: some View {
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

    /// The agents as a panel rising out of the bar, which a menu is too small to be. Always built, so the way out animates as well as the way in: a parent removed with its children never plays their transitions.
    var agentPicker: some View {
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

    func pageHeading(_ title: LocalizedStringKey, detail: String) -> some View {
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

    func page<Content: View>(_ which: HubTab, @ViewBuilder content: () -> Content) -> some View {
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
    var tabsItem: some ToolbarContent {
        if #available(iOS 26.0, *) {
            ToolbarItem(placement: .topBarTrailing) { tabSwitcher }
                .sharedBackgroundVisibility(.hidden)
        } else {
            ToolbarItem(placement: .topBarTrailing) { tabSwitcher }
        }
    }

    var dockIsShown: Bool {
        tab == .terminals || !model.availableAgents.isEmpty || model.hostSupportsFileBrowser
    }

    var terminalDock: some View {
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

    var agentDock: some View {
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

    func start(_ agent: TerminalAgent, restarting entry: AgentLaunch? = nil) {
        if !model.canOpenAnotherShell, let target = model.runningShellTargetID {
            model.launchAgent(agent, restarting: entry)
            path.append(.terminal(target))
        } else {
            model.launchAgent(agent, restarting: entry)
        }
        history = AgentHistory.load()
    }

    private func lastUsedLine(_ agent: TerminalAgent) -> String {
        // A chat is recorded by its folder, a terminal launch by its own history: either one is a use.
        let chatDate = AgentFolderHistory.load().first { $0.agentID == agent.id }?.date
        guard let date = [AgentHistory.lastUsed(agent, in: history), chatDate].compactMap({ $0 }).max() else {
            return String(localized: "Never used")
        }
        return String(localized: "Last used \(date.formatted(.relative(presentation: .named)))")
    }
}
