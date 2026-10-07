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
    @State var choosing: String?
    @State var tab: HubTab = HubTab(rawValue: UserDefaults.standard.string(forKey: "Peering.hubTab") ?? "") ?? .agents
    /// Both kinds behind one alert: two alerts on one screen means one does not present.
    @State var pendingEnd: PendingEnd?
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
                        : String(localized: "Chat with a coding agent on your Mac")
                )
                AgentToReviewCard()
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
                terminalHistorySection
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
                .reviewBottomBackdrop()
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



    // MARK: - Agents

    static let pickerSpring = Animation.spring(response: 0.45, dampingFraction: 0.78)



}
