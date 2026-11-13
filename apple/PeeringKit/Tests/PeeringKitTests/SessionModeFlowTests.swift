import Testing

@testable import PeeringKit

@Suite("Session mode flow")
struct SessionModeFlowTests {
    @Test("Screen and Remote share the pushed picture, Agents has its hub")
    func targets() {
        #expect(SessionModeFlow.target(for: .screen) == .surface)
        #expect(SessionModeFlow.target(for: .remote) == .surface)
        #expect(SessionModeFlow.target(for: .workspace) == .hub)
    }

    @Test("applying the mode the stack is already showing moves nothing")
    func retargetIsIdempotent() {
        #expect(SessionModeFlow.retarget(entering: .workspace, from: .hub) == nil)
        #expect(SessionModeFlow.retarget(entering: .remote, from: .surface) == nil)
    }

    @Test("entering a mode from the picker or from another mode moves the stack there")
    func retargetMoves() {
        #expect(SessionModeFlow.retarget(entering: .screen, from: .picker) == .surface)
        #expect(SessionModeFlow.retarget(entering: .workspace, from: .surface) == .hub)
        #expect(SessionModeFlow.retarget(entering: .remote, from: .hub) == .surface)
    }

    @Test("a resolved session re-applies its own mode")
    func resolvedReapplies() {
        let entry = SessionModeFlow.entry(modeResolved: true, current: .remote, remembered: .open(.screen))
        #expect(entry == .reapply(.remote))
    }

    @Test("a new session opens the remembered mode, or asks")
    func newSessionFollowsMemory() {
        #expect(SessionModeFlow.entry(modeResolved: false, current: .screen, remembered: .open(.workspace)) == .open(.workspace))
        #expect(SessionModeFlow.entry(modeResolved: false, current: .screen, remembered: .ask) == .ask)
    }

    @Test("the picker is the root once a mode is resolved or while one is asked for, and not while connecting")
    func rootIsPicker() {
        #expect(SessionModeFlow.rootIsPicker(modeResolved: true, asking: false))
        #expect(SessionModeFlow.rootIsPicker(modeResolved: false, asking: true))
        #expect(!SessionModeFlow.rootIsPicker(modeResolved: false, asking: false))
    }

    @Test("the stack rests on the picker when empty, the picture when it starts with it, and the hub otherwise")
    func targetFromFirstPage() {
        #expect(SessionModeFlow.target(firstPage: nil) == .picker)
        #expect(SessionModeFlow.target(firstPage: .screen) == .surface)
        #expect(SessionModeFlow.target(firstPage: .hub) == .hub)
        #expect(SessionModeFlow.target(firstPage: .step) == .hub)
    }

    @Test("the pages under the hub are the picture it was opened over, or none")
    func basePageCount() {
        #expect(SessionModeFlow.basePageCount(of: []) == 0)
        #expect(SessionModeFlow.basePageCount(of: [.hub, .step]) == 0)
        #expect(SessionModeFlow.basePageCount(of: [.screen, .hub, .step, .step]) == 1)
        #expect(SessionModeFlow.basePageCount(of: [.screen]) == 1)
    }
}
