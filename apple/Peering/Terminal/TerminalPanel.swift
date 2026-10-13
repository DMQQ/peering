import PeeringKit
import RemoteCore
import SwiftUI

enum TerminalFlowStep: Hashable {
    case terminal(UUID)
    case chat(UUID)
    case folder(TerminalAgent, String?)
    case files(String?)
    case terminalFolder(String?)
    case filePreview(String)
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

    /// One page per depth, so the swipe back is one level up. A folder already in the stack is returned to rather than stacked again, and the home folder counts: the first page names it as nil, and a ".." from its child names it by path.
    private func openFolder(_ target: String, _ step: (String) -> TerminalFlowStep) {
        let destination = step(target)
        let home = model.agentPicker.startPath
        if let index = path.lastIndex(where: { Self.page($0, shows: destination, home: home) }) {
            path = Array(path[...index])
        } else if let top = path.last, let shown = folder(of: top, home: home), Self.concreteFolder(of: destination, home: home).map({ Self.isAncestor($0, of: shown) }) == true {
            // A parent nobody visited takes the current page's place. Inserting under it and popping it on a later tick was two stack edits racing the navigation controller, which left it on the old page with the swipe back dead.
            var replaced = path
            replaced[replaced.count - 1] = destination
            path = replaced
        } else {
            path.append(destination)
        }
    }

    /// A page that names no folder shows the one its model is on: the browser's for Files, the picker's for the others. Without that, the first page (and a page restored from the remembered folder) never looks like a child of anything.
    private func folder(of page: TerminalFlowStep, home: String?) -> String? {
        switch page {
        case .files(let folder): folder ?? model.browserPath
        case .folder(_, let folder), .terminalFolder(let folder): folder ?? model.agentPicker.path ?? home
        case .terminal, .chat, .filePreview: nil
        }
    }

    private static func concreteFolder(of page: TerminalFlowStep, home: String?) -> String? {
        switch page {
        case .folder(_, let folder), .files(let folder), .terminalFolder(let folder): folder ?? home
        case .terminal, .chat, .filePreview: nil
        }
    }

    private static func isAncestor(_ ancestor: String, of folder: String) -> Bool {
        ancestor != folder && (ancestor == "/" || folder.hasPrefix(ancestor + "/"))
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

    var body: some View {
        if let step {
            // Keyed by the step: ".." replaces the top page, and without a new identity the picker keeps the listing it already loaded.
            page(for: step).id(step)
        } else {
            hub
        }
    }

    private var hub: some View {
        TerminalHubScreen(path: pathBinding)
            .navigationBarTitleDisplayMode(.inline)
            .toolbarBackground(ColorPalette.backdrop, for: .navigationBar)
            .toolbarBackground(.visible, for: .navigationBar)
            .preferredColorScheme(.dark)
            .onAppear {
                // A shell or chat made while the hub was away was already opened by its maker; do not jump to it.
                model.newTerminalID = nil
                model.newAgentSessionID = nil
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
            MacFilesScreen(path: directory, push: { openFolder($0) { .files($0) } }, close: { path = [] }, preview: { path.append(.filePreview($0)) })
        case .filePreview(let file):
            MacFilePreviewScreen(path: file)
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
