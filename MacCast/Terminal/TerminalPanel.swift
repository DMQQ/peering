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
    /// Nil for the hub itself. A page is built by a panel of its own, because its closures read the environment, which only a view in the hierarchy has.
    var step: TerminalFlowStep?

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

    /// One page per depth, so the swipe back is one level up. A folder already in the stack is returned to rather than stacked again, and the home folder counts: the first page names it as nil, and a ".." from its child names it by path.
    private func openFolder(_ target: String, _ step: (String) -> TerminalFlowStep) {
        let destination = step(target)
        let home = model.agentPicker.startPath
        if let index = path.lastIndex(where: { Self.page($0, shows: destination, home: home) }) {
            path = Array(path[...index])
        } else {
            path.append(destination)
        }
    }

    private static func page(_ page: TerminalFlowStep, shows destination: TerminalFlowStep, home: String?) -> Bool {
        if page == destination { return true }
        switch (page, destination) {
        case (.folder(let agent, nil), .folder(let other, let folder?)):
            return agent == other && folder == home
        case (.terminalFolder(nil), .terminalFolder(let folder?)):
            return folder == home
        default:
            return false
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
        if let step {
            page(for: step)
        } else {
            hub
        }
    }

    private var hub: some View {
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
                AgentFolderHistory.record(directory: directory, agentID: AgentFolderHistory.terminalAgentID, macName: model.hostName)
                model.createTerminal(inDirectory: directory)
            }
        }
    }
}
