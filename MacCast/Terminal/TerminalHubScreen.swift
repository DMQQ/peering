import MacCastKit
import RemoteCore
import SwiftUI

struct TerminalHubScreen: View {
    @Binding var path: [TerminalFlowStep]
    @Environment(SessionModel.self) var model

    @State var history = AgentHistory.load()
    /// Bumped when the terminal history is cleared, so the section reads the store again.
    @State var terminalHistoryRevision = 0
    @State var selectedAgentID: String?
    @State var pickerOpen = false
    /// Files is built on first visit: it lists a folder on the Mac as soon as it appears.
    @State var filesVisited = false
    @State var choosing: String?
    @State var tab: HubTab = HubTab(rawValue: UserDefaults.standard.string(forKey: "Peering.hubTab") ?? "") ?? .agents
    /// Both kinds behind one alert: two alerts on one screen means one does not present.
    @State var pendingEnd: PendingEnd?
    @AppStorage("Peering.agentsGuideSeen") var agentsGuideSeen = false
    @AppStorage("Peering.terminalsGuideSeen") var terminalsGuideSeen = false
    @State var renaming: Renaming?
    @State var renameText = ""

    enum PendingEnd: Equatable {
        case terminal(UUID)
        case chat(UUID)
    }

    enum Renaming: Equatable {
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
                        : String(localized: "Chat with a coding agent on your Mac"),
                    guideSeen: $agentsGuideSeen
                )
                guide(.agents)
                AgentToReviewCard()
                chatsSection
                activeOnMacSection
                pausedChatsSection
                agentsNotice
                historySection
            }
            page(.terminals) {
                pageHeading(
                    "Terminals",
                    detail: model.shownHostName.map { String(localized: "Shells running on \($0)") }
                        ?? String(localized: "Shells running on your Mac"),
                    guideSeen: $terminalsGuideSeen
                )
                guide(.terminals)
                terminalsSection
                terminalHistorySection
            }
            if filesVisited, model.hostSupportsFileBrowser { filesPage.transition(.identity) }
        }
        .animation(Self.tabFade, value: tab)
        .onChange(of: tab) { _, tab in tabChanged(to: tab) }
        .onAppear { restoreTab() }
        .analyticsScreen(.terminals)
        .scrollBounceBehavior(.basedOnSize)
        .navigationTitle(model.shownHostName ?? String(localized: "Your Mac"))
        .safeAreaInset(edge: .top, spacing: 0) { tabSwitcher.background(ColorPalette.backdrop) }
        // An overlay and not a bottom inset: an inset resizes every page, including the hidden Files page, so each tab switch re-laid out its search row against the dock.
        .overlay(alignment: .bottom) {
            if dockIsShown {
                dock
                    .reviewBottomBackdrop()
                    // Leaving Files, the Files bar goes first and this one fades in behind it, so the two are never on screen together. Going to Files it leaves at once.
                    .transition(.asymmetric(insertion: .opacity.animation(Self.tabFade.delay(0.1)), removal: .identity))
            }
        }
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
        .onAppear {
            model.refreshAgents()
            model.refreshResumableSessions()
            model.ensureAgentPreviews()
        }
        // The section draws nothing until the list arrives, so it cannot ask for it itself: an onAppear on an empty view never fires.
        .onChange(of: model.hostSupportsAgentSessionImport) { _, _ in model.refreshResumableSessions() }
        .onChange(of: model.agentCards.map(\.id)) { _, _ in model.ensureAgentPreviews() }
    }



    private func tabChanged(to tab: HubTab) {
        UserDefaults.standard.set(tab.rawValue, forKey: "Peering.hubTab")
        if tab == .files { filesVisited = true }
        let panel: Analytics.Panel
        switch tab {
        case .agents: panel = .agents
        case .terminals: panel = .terminals
        case .files: panel = .files
        }
        Analytics.panelOpened(panel)
    }

    /// A remembered Files tab on a Mac that cannot browse falls back to Agents.
    private func restoreTab() {
        guard tab == .files else { return }
        if model.hostSupportsFileBrowser { filesVisited = true } else { tab = .agents }
    }

    // MARK: - Agents

    /// One fade for the pages, the docks and the Files bar, so a tab change moves everything together.
    static let tabFade = Animation.easeOut(duration: 0.12)
    static let tabFadeOut = Animation.easeOut(duration: 0.08)

    static let pickerSpring = Animation.spring(response: 0.45, dampingFraction: 0.78)



}
