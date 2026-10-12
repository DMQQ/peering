import Foundation
import RemoteCore
import Testing

@testable import MacCastKit

@Suite("Live Activity push planner")
struct LiveActivityPushPlannerTests {
    private let t0 = ContinuousClock.now

    private func tokens(_ kind: LiveActivityKind, token: String? = "aa", start: String? = nil) -> ActivityTokenPayload {
        ActivityTokenPayload(activity: kind, pushToken: token, pushToStartToken: start, environment: .production)
    }

    private func truth(
        _ phase: LiveActivityTruth.Phase = .active,
        chats: [LiveActivityChat] = []
    ) -> LiveActivityTruth {
        LiveActivityTruth(phase: phase, startedAt: Date(timeIntervalSince1970: 999_000), path: .lan, chats: chats)
    }

    private func chat(_ id: String, _ state: LiveActivityChat.State) -> LiveActivityChat {
        LiveActivityChat(id: id, symbol: "sparkles", state: state)
    }

    private func planner(_ kind: LiveActivityKind = .session, start: String? = nil) -> LiveActivityPushPlanner {
        var planner = LiveActivityPushPlanner()
        planner.tokensChanged(tokens(kind, start: start))
        return planner
    }

    // MARK: Who gets a push

    @Test("a foreground phone is never pushed to, and a gone or backgrounded one is, when it has a token")
    func policy() {
        #expect(!PushPolicy.shouldPush(presence: .foreground, hasToken: true))
        #expect(PushPolicy.shouldPush(presence: .background, hasToken: true))
        #expect(PushPolicy.shouldPush(presence: .gone, hasToken: true))
        #expect(!PushPolicy.shouldPush(presence: .gone, hasToken: false))
        #expect(!PushPolicy.shouldPush(presence: .background, hasToken: false))
    }

    @Test("a phone is foreground while any of its connections is")
    func presenceBook() {
        var book = PhonePresenceBook()
        let lan = UUID(), relay = UUID()
        #expect(book.presence(of: "p") == .gone)
        book.connected(clientID: "p", session: lan)
        book.connected(clientID: "p", session: relay)
        book.backgroundChanged(clientID: "p", session: lan, background: true)
        #expect(book.presence(of: "p") == .foreground)
        book.backgroundChanged(clientID: "p", session: relay, background: true)
        #expect(book.presence(of: "p") == .background)
        book.backgroundChanged(clientID: "p", session: lan, background: false)
        #expect(book.presence(of: "p") == .foreground)
        book.disconnected(clientID: "p", session: lan)
        #expect(book.presence(of: "p") == .background)
        book.disconnected(clientID: "p", session: relay)
        #expect(book.presence(of: "p") == .gone)
    }

    @Test("a background flag for a connection never announced changes nothing")
    func strayBackground() {
        var book = PhonePresenceBook()
        book.backgroundChanged(clientID: "p", session: UUID(), background: true)
        #expect(book.presence(of: "p") == .gone)
    }

    // MARK: Session card

    @Test("nothing is pushed while the phone is in the foreground")
    func foregroundSilent() {
        var planner = planner()
        #expect(planner.observe(truth(), presence: .foreground, now: t0).isEmpty)
    }

    @Test("a backgrounded phone gets one update, and a repeat of the same state gets none")
    func updateOnce() {
        var planner = planner()
        let first = planner.observe(truth(), presence: .background, now: t0)
        #expect(first.count == 1)
        #expect(first.first?.event == .update)
        #expect(first.first?.token == "aa")
        #expect(planner.observe(truth(), presence: .background, now: t0.addingTimeInterval(5)).isEmpty)
    }

    @Test("a change inside the gap is held and the latest state goes when it is due")
    func coalescing() {
        var planner = planner()
        _ = planner.observe(truth(), presence: .background, now: t0)
        var changed = truth()
        changed.path = .relay
        #expect(planner.observe(changed, presence: .background, now: t0.addingTimeInterval(0.2)).isEmpty)
        changed.path = .direct
        #expect(planner.observe(changed, presence: .background, now: t0.addingTimeInterval(0.4)).isEmpty)
        #expect(planner.nextDue == t0.addingTimeInterval(1))
        #expect(planner.due(now: t0.addingTimeInterval(0.9)).isEmpty)
        let sent = planner.due(now: t0.addingTimeInterval(1))
        #expect(sent.count == 1)
        #expect(sent.first?.truth.path == .direct)
        #expect(planner.nextDue == nil)
    }

    @Test("coming back to the foreground forgets what was pushed, so leaving again pushes the state")
    func returnResets() {
        var planner = planner()
        _ = planner.observe(truth(), presence: .background, now: t0)
        _ = planner.observe(truth(), presence: .foreground, now: t0.addingTimeInterval(10))
        #expect(planner.observe(truth(), presence: .background, now: t0.addingTimeInterval(20)).count == 1)
    }

    @Test("a session ended from the Mac sends end once the gap allows, and not again")
    func endImmediate() {
        var planner = planner()
        _ = planner.observe(truth(), presence: .background, now: t0)
        let sent = planner.observe(truth(.ended), presence: .gone, now: t0.addingTimeInterval(1))
        #expect(sent.first?.event == .end)
        #expect(planner.observe(truth(.ended), presence: .gone, now: t0.addingTimeInterval(5)).isEmpty)
    }

    @Test("an end inside the gap waits for it, and the host stopping sends it at once")
    func endObeysGap() {
        var held = planner()
        _ = held.observe(truth(), presence: .background, now: t0)
        #expect(held.observe(truth(.ended), presence: .gone, now: t0.addingTimeInterval(0.1)).isEmpty)
        #expect(held.nextDue == t0.addingTimeInterval(1))
        #expect(held.due(now: t0.addingTimeInterval(1)).first?.event == .end)
        var stopping = planner()
        _ = stopping.observe(truth(), presence: .background, now: t0)
        let sent = stopping.observe(truth(.ended), presence: .gone, now: t0.addingTimeInterval(0.1), ignoringGap: true)
        #expect(sent.first?.event == .end)
    }

    @Test("a finished card's end waits out the gap without asking to be woken again at once")
    func lingerEndHonoursGap() {
        var planner = planner(.agentChat)
        let state = truth(chats: [chat("c", .finished)])
        _ = planner.observe(state, presence: .background, now: t0)
        let due = t0.addingTimeInterval(30 * 60)
        let ending = planner.observe(truth(chats: [chat("c", .working)]), presence: .background, now: due)
        #expect(ending.count == 1)
        _ = planner.observe(state, presence: .background, now: due.addingTimeInterval(2))
        #expect(planner.nextDue == due.addingTimeInterval(2 + 30 * 60))
    }

    @Test("the gap belongs to the token, so two cards on one token share it and two tokens do not")
    func gapPerToken() {
        var shared = LiveActivityPushPlanner()
        shared.tokensChanged(tokens(.session, token: "same"))
        shared.tokensChanged(tokens(.agentChat, token: "same"))
        let first = shared.observe(truth(chats: [chat("c", .working)]), presence: .background, now: t0)
        #expect(first.count == 1)
        var separate = LiveActivityPushPlanner()
        separate.tokensChanged(tokens(.session, token: "one"))
        separate.tokensChanged(tokens(.agentChat, token: "two"))
        #expect(separate.observe(truth(chats: [chat("c", .working)]), presence: .background, now: t0).count == 2)
    }

    @Test("a connection lost without anyone ending it pushes the dropped state")
    func dropped() {
        var planner = planner()
        let sent = planner.observe(truth(.dropped), presence: .gone, now: t0)
        #expect(sent.first?.event == .update)
        #expect(sent.first?.truth.phase == .dropped)
    }

    @Test("an active session with no connection pushes nothing")
    func activeButGone() {
        var planner = planner()
        #expect(planner.observe(truth(), presence: .gone, now: t0).isEmpty)
    }

    @Test("an activity the phone ended is never pushed to")
    func endedByPhone() {
        var planner = planner()
        planner.tokensChanged(tokens(.session, token: nil))
        #expect(planner.observe(truth(), presence: .background, now: t0).isEmpty)
    }

    @Test("a token the relay refused is dropped and not retried")
    func forgetToken() {
        var planner = planner()
        planner.forget(token: "aa")
        #expect(planner.observe(truth(), presence: .background, now: t0).isEmpty)
    }

    // MARK: Agent chat card

    @Test("a chat waiting on approval is pushed at priority 10 with an approval alert")
    func needsApproval() {
        var planner = planner(.agentChat)
        let sent = planner.observe(truth(chats: [chat("c", .needsYou)]), presence: .background, now: t0)
        #expect(sent.first?.event == .update)
        #expect(sent.first?.priority == 10)
        #expect(sent.first?.alert == .needsApproval)
    }

    @Test("work in progress is pushed with no alert")
    func workingQuiet() {
        var planner = planner(.agentChat)
        let sent = planner.observe(truth(chats: [chat("c", .working)]), presence: .background, now: t0)
        #expect(sent.first?.alert == nil)
        #expect(sent.first?.priority == nil)
    }

    @Test("a chat that finishes or fails is pushed with its alert once")
    func finishedAndFailed() {
        var planner = planner(.agentChat)
        _ = planner.observe(truth(chats: [chat("c", .working)]), presence: .background, now: t0)
        let done = planner.observe(truth(chats: [chat("c", .finished)]), presence: .background, now: t0.addingTimeInterval(2))
        #expect(done.first?.alert == .finished)
        let failed = planner.observe(truth(chats: [chat("d", .failed), chat("c", .finished)]), presence: .background, now: t0.addingTimeInterval(4))
        #expect(failed.first?.alert == .failed)
        #expect(failed.first?.truth.topChat?.id == "d")
    }

    @Test("an alert is not repeated when the phone leaves and returns with nothing new")
    func alertOnce() {
        var planner = planner(.agentChat)
        let state = truth(chats: [chat("c", .finished)])
        #expect(planner.observe(state, presence: .background, now: t0).first?.alert == .finished)
        _ = planner.observe(state, presence: .foreground, now: t0.addingTimeInterval(5))
        #expect(planner.observe(state, presence: .background, now: t0.addingTimeInterval(10)).first?.alert == nil)
    }

    @Test("newer work takes the headline from a finished chat")
    func replacedByNewerWork() {
        var planner = planner(.agentChat)
        _ = planner.observe(truth(chats: [chat("old", .finished)]), presence: .background, now: t0)
        let sent = planner.observe(truth(chats: [chat("new", .working), chat("old", .finished)]), presence: .background, now: t0.addingTimeInterval(3))
        #expect(sent.first?.truth.topChat?.id == "new")
        #expect(planner.nextDue == nil)
    }

    @Test("the card for finished work comes down thirty minutes after it settled, not before")
    func dismissalTiming() {
        var planner = planner(.agentChat)
        let state = truth(chats: [chat("c", .finished)])
        _ = planner.observe(state, presence: .background, now: t0)
        let due = t0.addingTimeInterval(30 * 60)
        #expect(planner.nextDue == due)
        #expect(planner.due(now: due.addingTimeInterval(-1)).isEmpty)
        let ended = planner.due(now: due)
        #expect(ended.first?.event == .end)
        #expect(ended.first?.dismissalSeconds == 0)
        #expect(planner.due(now: due.addingTimeInterval(60)).isEmpty)
        #expect(planner.nextDue == nil)
    }

    @Test("a failed chat's card is also taken down at once when its thirty minutes are up, and a session card leaves it to the relay")
    func dismissalSecondsOnEnd() {
        var chats = planner(.agentChat)
        _ = chats.observe(truth(chats: [chat("c", .failed)]), presence: .background, now: t0)
        #expect(chats.due(now: t0.addingTimeInterval(30 * 60)).first?.dismissalSeconds == 0)
        var session = planner(.session)
        _ = session.observe(truth(), presence: .background, now: t0)
        let ended = session.observe(truth(.ended), presence: .background, now: t0.addingTimeInterval(5))
        #expect(ended.first?.event == .end)
        #expect(ended.first?.dismissalSeconds == nil)
    }

    @Test("work that returns to a finished card before the linger ends restarts nothing and keeps the card")
    func workCancelsLinger() {
        var planner = planner(.agentChat)
        _ = planner.observe(truth(chats: [chat("c", .finished)]), presence: .background, now: t0)
        _ = planner.observe(truth(chats: [chat("c", .working)]), presence: .background, now: t0.addingTimeInterval(60))
        #expect(planner.nextDue == nil)
        #expect(planner.due(now: t0.addingTimeInterval(31 * 60)).isEmpty)
    }

    @Test("with no card up, an approval starts one through the push-to-start token with an alert")
    func startOnApproval() {
        var planner = LiveActivityPushPlanner()
        planner.tokensChanged(tokens(.agentChat, token: nil, start: "bb"))
        let sent = planner.observe(truth(chats: [chat("c", .needsYou)]), presence: .background, now: t0)
        #expect(sent.first?.event == .start)
        #expect(sent.first?.token == "bb")
        #expect(sent.first?.alert == .needsApproval)
        #expect(planner.observe(truth(chats: [chat("c", .needsYou)]), presence: .background, now: t0.addingTimeInterval(5)).isEmpty)
    }

    @Test("with no card up, work that does not need the person starts nothing")
    func noStartForWork() {
        var planner = LiveActivityPushPlanner()
        planner.tokensChanged(tokens(.agentChat, token: nil, start: "bb"))
        #expect(planner.observe(truth(chats: [chat("c", .working)]), presence: .background, now: t0).isEmpty)
        #expect(planner.observe(truth(chats: [chat("c", .finished)]), presence: .background, now: t0.addingTimeInterval(2)).isEmpty)
    }

    @Test("once the started card reports its own token, updates flow to it")
    func updatesAfterStart() {
        var planner = LiveActivityPushPlanner()
        planner.tokensChanged(tokens(.agentChat, token: nil, start: "bb"))
        _ = planner.observe(truth(chats: [chat("c", .needsYou)]), presence: .background, now: t0)
        planner.tokensChanged(tokens(.agentChat, token: "cc", start: "bb"))
        let sent = planner.observe(truth(chats: [chat("c", .working)]), presence: .background, now: t0.addingTimeInterval(3))
        #expect(sent.first?.event == .update)
        #expect(sent.first?.token == "cc")
    }

    @Test("no start while the phone is in the foreground")
    func noStartInForeground() {
        var planner = LiveActivityPushPlanner()
        planner.tokensChanged(tokens(.agentChat, token: nil, start: "bb"))
        #expect(planner.observe(truth(chats: [chat("c", .needsYou)]), presence: .foreground, now: t0).isEmpty)
    }

    @Test("after the card is taken down, a new approval starts another")
    func startAfterDismissal() {
        var planner = LiveActivityPushPlanner()
        planner.tokensChanged(tokens(.agentChat, token: "aa", start: "bb"))
        _ = planner.observe(truth(chats: [chat("c", .finished)]), presence: .background, now: t0)
        _ = planner.due(now: t0.addingTimeInterval(30 * 60))
        let sent = planner.observe(truth(chats: [chat("d", .needsYou)]), presence: .background, now: t0.addingTimeInterval(31 * 60))
        #expect(sent.first?.event == .start)
        #expect(sent.first?.token == "bb")
    }

    @Test("a chat card with no chats left ends only a card this Mac pushed")
    func emptyChats() {
        var planner = planner(.agentChat)
        #expect(planner.observe(truth(), presence: .background, now: t0).isEmpty)
        _ = planner.observe(truth(chats: [chat("c", .working)]), presence: .background, now: t0.addingTimeInterval(2))
        #expect(planner.observe(truth(), presence: .background, now: t0.addingTimeInterval(4)).first?.event == .end)
    }

    @Test("chats keep being pushed after the connection is lost, and an approval can start a card")
    func chatsWithoutConnection() {
        var planner = LiveActivityPushPlanner()
        planner.tokensChanged(tokens(.agentChat, token: "aa", start: "bb"))
        let dropped = truth(.dropped, chats: [chat("c", .needsYou)])
        #expect(planner.observe(dropped, presence: .gone, now: t0).first?.event == .update)
        var starter = LiveActivityPushPlanner()
        starter.tokensChanged(tokens(.agentChat, token: nil, start: "bb"))
        #expect(starter.observe(dropped, presence: .gone, now: t0).first?.event == .start)
    }

    @Test("after a refusal that was nobody's fault, the same state is pushed again")
    func resendAfterBackoff() {
        var planner = planner()
        _ = planner.observe(truth(), presence: .background, now: t0)
        planner.resend()
        #expect(planner.observe(truth(), presence: .background, now: t0.addingTimeInterval(61)).count == 1)
    }
}
