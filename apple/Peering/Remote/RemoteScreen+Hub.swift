import PeeringKit
import SwiftUI

extension RemoteScreen {
    /// A sideways phone answers compact height, and a wide iPad regular width. Traits, not geometry, which reads landscape for an upright phone with its keyboard up.
    var hubIsSplit: Bool {
        horizontalSizeClass == .regular || verticalSizeClass == .compact
    }

    /// Split, the hub is not pushed at all: the stack sees only the pages under it, and ``hubSplit`` shows the hub over them.
    var pushedRoute: Binding<[RemoteRoute]> {
        Binding(
            get: { hubIsSplit ? route.base : route },
            set: { route = hubIsSplit ? $0 + route.drop { $0 != .hub } : $0 }
        )
    }

    @ViewBuilder
    var hubSplit: some View {
        if hubIsSplit, route.hubIsOpen {
            HubSplitView(route: $route)
                .transition(.opacity)
        }
    }

    /// A shell or chat the Mac has just made opens on top of the pages that asked for it. Handled here, on the stack's owner, because the hub and its pages are covered by whatever is pushed above them and a covered page is not reliably told of a change.
    func openCreated(_ step: TerminalFlowStep) {
        let steps = route.steps
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
        route = route.withHub(steps: kept + [step])
    }

    /// A tap on an in-app card, or a link from outside, asks for a chat or a shell by id.
    func openFromBanner() {
        guard let target = InAppBanner.shared.takeOpenRequest() else { return }
        switch target {
        case .chat(let id):
            model.selectedAgentSessionID = id
            route = route.withHub(steps: [.chat(id)])
        case .terminal(let id):
            route = route.withHub(steps: [.terminal(id)])
        case .sshTerminal:
            break
        }
    }
}
