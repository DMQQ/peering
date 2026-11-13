import PeeringKit

extension [RemoteRoute] {
    /// What the stack is resting on: nothing pushed is the picker, the pushed picture is Screen or Remote, and the hub is Agents. A hub pushed over the picture is still resting on the picture.
    var target: SessionModeFlow.Target {
        SessionModeFlow.target(firstPage: first?.kind)
    }

    var hubIsOpen: Bool { contains(.hub) }

    /// The pages under the hub: the picture it was opened over, or nothing.
    var base: [RemoteRoute] { Array(prefix(SessionModeFlow.basePageCount(of: map(\.kind)))) }

    var steps: [TerminalFlowStep] {
        compactMap {
            if case .step(let step) = $0 { step } else { nil }
        }
    }

    /// The hub with these pages above it, over whatever it was opened over.
    func withHub(steps: [TerminalFlowStep]) -> [RemoteRoute] {
        base + [.hub] + steps.map(RemoteRoute.step)
    }

    static func resting(on target: SessionModeFlow.Target) -> [RemoteRoute] {
        switch target {
        case .picker: []
        case .surface: [.screen]
        case .hub: [.hub]
        }
    }
}

extension RemoteRoute {
    var kind: SessionModeFlow.PageKind {
        switch self {
        case .screen: .screen
        case .hub: .hub
        case .step: .step
        }
    }
}
