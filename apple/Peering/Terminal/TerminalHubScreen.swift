import PeeringKit
import RemoteCore
import SwiftUI

struct TerminalHubScreen: View {
    @Binding var path: [TerminalFlowStep]
    @Environment(SessionModel.self) var model

    /// Read once the page is up: an initial value here would decode the store on every pass the parent makes over this view.
    @State var history: [AgentLaunch] = []
    /// Bumped when the terminal history is cleared, so the section reads the store again.
    @State var terminalHistoryRevision = 0
    @State var agentHistoryQuery = ""
    @State var terminalHistoryQuery = ""
    @State var selectedAgentID: String?
    @State var pickerOpen = false
    /// A page is built on first visit and kept after: Files lists a folder on the Mac as soon as it appears, and tearing a page down on each switch was the lag.
    @State var visitedTabs: Set<HubTab> = []
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
        // A visited page stays built, so a switch only changes opacity.
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
            if isBuilt(.files), model.hostSupportsFileBrowser { filesPage.transition(.identity) }
        }
        .animation(Self.tabFade, value: tab)
        .onChange(of: tab) { old, tab in
            visitedTabs.formUnion([old, tab])
            tabChanged(to: tab)
        }
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
        .task { await refreshOnceSettled() }
        .task(id: tab) { await keepResumableSessionsFresh() }
        // The section draws nothing until the list arrives, so it cannot ask for it itself: an onAppear on an empty view never fires.
        .onChange(of: model.hostSupportsAgentSessionImport) { _, _ in model.refreshResumableSessions() }
        .onChange(of: model.agentCards.map(\.id)) { _, _ in model.ensureAgentPreviews() }
    }

    /// Whether a conversation is open on the Mac is the host's guess from when its file was last written, so the list goes stale on its own: asked again while the Agents page is up.
    private func keepResumableSessionsFresh() async {
        guard tab == .agents else { return }
        while !Task.isCancelled {
            do { try await Task.sleep(for: Self.resumableRefresh) } catch { return }
            model.refreshResumableSessions()
        }
    }

    private func tabChanged(to tab: HubTab) {
        UserDefaults.standard.set(tab.rawValue, forKey: "Peering.hubTab")
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
        if !model.hostSupportsFileBrowser { tab = .agents }
    }

    func isBuilt(_ page: HubTab) -> Bool { tab == page || visitedTabs.contains(page) }

    /// The hub is pushed onto the remote screen's stack. Every request below answers by changing observed state, and a re-render in the middle of the slide is the stutter, so they wait for it to land.
    private func refreshOnceSettled() async {
        history = AgentHistory.load()
        do { try await Task.sleep(for: Self.pushSettle) } catch { return }
        model.refreshTerminals()
        model.refreshAgents()
        model.refreshAgentSessions()
        model.refreshResumableSessions()
        model.ensureAgentPreviews()
    }

    // MARK: - Agents

    static let pushSettle = Duration.milliseconds(400)
    static let resumableRefresh = Duration.seconds(10)

    /// One fade for the pages, the docks and the Files bar, so a tab change moves everything together.
    static let tabFade = Animation.easeOut(duration: 0.12)
    static let tabFadeOut = Animation.easeOut(duration: 0.08)

    static let pickerSpring = Animation.spring(response: 0.45, dampingFraction: 0.78)
}
