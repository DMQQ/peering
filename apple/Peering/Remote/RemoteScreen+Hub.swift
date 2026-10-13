import MacCastKit
import SwiftUI

extension RemoteScreen {
    /// A shell or chat the Mac has just made opens on top of the pages that asked for it. Handled here, on the stack's owner, because the hub and its pages are covered by whatever is pushed above them and a covered page is not reliably told of a change.
    func openCreated(_ step: TerminalFlowStep) {
        let steps = route.compactMap { entry -> TerminalFlowStep? in
            if case .step(let step) = entry { step } else { nil }
        }
        // Only from the list or from the picker that asked: never over a page the person is reading.
        switch steps.last {
        case nil, .folder, .terminalFolder: break
        default: return
        }
        // The folder pages were only the way to the new session: back from it lands on the list, not on a folder.
        let kept = steps.filter {
            switch $0 {
            case .folder, .terminalFolder, .files: false
            default: true
            }
        }
        route = [.hub] + (kept + [step]).map(RemoteRoute.step)
    }

    /// A tap on an in-app card, or a link from outside, asks for a chat or a shell by id.
    func openFromBanner() {
        guard let target = InAppBanner.shared.takeOpenRequest() else { return }
        switch target {
        case .chat(let id):
            model.selectedAgentSessionID = id
            route = [.hub, .step(.chat(id))]
        case .terminal(let id):
            route = [.hub, .step(.terminal(id))]
        case .sshTerminal:
            break
        }
    }
}
