import RemoteCore
import SwiftUI
import UIKit

/// What a card is about, and so what a tap on it opens and what makes it redundant.
enum InAppBannerTarget: Equatable {
    case chat(UUID)
    case terminal(UUID)
    /// An SSH shell lives in this phone, not on a Mac: it can quiet its own cards but has no page to open.
    case sshTerminal(UUID)

    var opensScreen: Bool {
        if case .sshTerminal = self { false } else { true }
    }
}

struct InAppBannerItem: Identifiable {
    let id = UUID()
    let symbol: String
    let title: String
    let summary: String
    /// Shown in full once expanded: the command asked about, or the end of the reply.
    let body: String?
    let needsYou: Bool
    /// Nil for news with nowhere to go, which gets no open button.
    let target: InAppBannerTarget?
    var openLabel: LocalizedStringKey = "Open chat"
    /// Labels of a question's answers; empty for an allow or deny ask.
    var options: [String] = []
    var respond: ((AgentApprovalDecision) -> Void)?

    var asksApproval: Bool { respond != nil }
}

/// What the banner window shows, and the chat a tap on it asks for.
@Observable
@MainActor
final class InAppBanner {
    static let shared = InAppBanner()

    private(set) var current: InAppBannerItem?
    var isExpanded = false
    /// Where the card is on screen, so the overlay window lets every other touch through.
    var cardFrame: CGRect = .zero
    /// Taken (set back to nil) by the screen that opens it.
    var openRequest: InAppBannerTarget? {
        didSet { openRequestedAt = openRequest == nil ? nil : MonotonicStamp() }
    }
    private var openRequestedAt: MonotonicStamp?
    /// What the person is reading now: news about it is not news.
    var onScreen: InAppBannerTarget? {
        didSet {
            if let onScreen, onScreen == current?.target { dismiss() }
        }
    }

    /// A request nobody took (the connection it waited for never came up) must not open a screen minutes later.
    var freshOpenRequest: InAppBannerTarget? {
        guard let openRequestedAt, openRequestedAt.isWithin(seconds: 60) else { return nil }
        return openRequest
    }

    func takeOpenRequest() -> InAppBannerTarget? {
        defer { openRequest = nil }
        return freshOpenRequest
    }

    /// Only the screen that set it may clear it: when one chat replaces another, the old one's disappearance can arrive after the new one's appearance.
    func leave(_ target: InAppBannerTarget) {
        if onScreen == target { onScreen = nil }
    }

    private var dismissTask: Task<Void, Never>?
    private var expandTask: Task<Void, Never>?

    static let entrance = Animation.spring(response: 0.55, dampingFraction: 0.56)
    static let reshape = Animation.spring(response: 0.5, dampingFraction: 0.68)
    private static let leave = Animation.spring(response: 0.38, dampingFraction: 0.9)

    func post(_ item: InAppBannerItem) {
        guard item.target == nil || item.target != onScreen else { return }
        expandTask?.cancel()
        isExpanded = false
        let windowWasUp = current != nil
        InAppBannerWindow.shared.show()
        // **The window must render once without the card.** A hosting view built with the item already set draws it in its first frame, so the insertion transition has nothing to run from and the card pops in.
        expandTask = Task { [weak self] in
            if !windowWasUp { try? await Task.sleep(for: .milliseconds(60)) }
            guard !Task.isCancelled, let self else { return }
            withAnimation(Self.entrance) { current = item }
            schedule()
            // A question has buttons: the card arrives as a drop and then opens, which is the liquid part.
            if item.asksApproval {
                try? await Task.sleep(for: .milliseconds(520))
                guard !Task.isCancelled else { return }
                setExpanded(true)
            }
        }
    }

    func setExpanded(_ expanded: Bool) {
        guard current != nil, isExpanded != expanded else { return }
        withAnimation(Self.reshape) { isExpanded = expanded }
        schedule()
    }

    func answer(_ decision: AgentApprovalDecision) {
        current?.respond?(decision)
        dismiss()
    }

    func dismiss() {
        dismissTask?.cancel()
        expandTask?.cancel()
        guard current != nil else { return }
        withAnimation(Self.leave) { current = nil; isExpanded = false }
        Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(600))
            if self?.current == nil { InAppBannerWindow.shared.hide() }
        }
    }

    /// The question was answered somewhere else, so the card has nothing left to ask.
    func resolve(chatID: UUID) {
        if current?.target == .chat(chatID), current?.asksApproval == true { dismiss() }
    }

    func open() {
        if current?.target?.opensScreen == true { openRequest = current?.target }
        dismiss()
    }

    /// Every card leaves on its own: a compact one soon, an open one after a longer read. Touching it starts the clock again.
    func schedule() {
        dismissTask?.cancel()
        let seconds: Double = isExpanded ? (current?.asksApproval == true ? 25 : 12) : 5
        dismissTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(seconds))
            guard !Task.isCancelled else { return }
            if self?.isExpanded == true {
                self?.setExpanded(false)
            } else {
                self?.dismiss()
            }
        }
    }
}

/// A drop that grows out of the top edge and settles, with the blur and overshoot of a liquid.
struct LiquidDrop: Transition {
    func body(content: Content, phase: TransitionPhase) -> some View {
        content
            .scaleEffect(x: phase.isIdentity ? 1 : 0.45, y: phase.isIdentity ? 1 : 0.2, anchor: .top)
            .blur(radius: phase.isIdentity ? 0 : 14)
            .opacity(phase.isIdentity ? 1 : 0)
            .offset(y: phase.isIdentity ? 0 : -20)
    }
}

/// Above sheets and full-screen covers, which a view overlay on the root would sit under. Only the card takes touches: everything else falls through to the app.
@MainActor
final class InAppBannerWindow {
    static let shared = InAppBannerWindow()

    private var window: PassthroughWindow?

    func show() {
        guard window == nil,
              let scene = UIApplication.shared.connectedScenes
                .compactMap({ $0 as? UIWindowScene })
                .first(where: { $0.activationState == .foregroundActive })
        else { return }
        let window = PassthroughWindow(windowScene: scene)
        window.windowLevel = .alert + 1
        window.backgroundColor = .clear
        let host = UIHostingController(rootView: InAppBannerView(banner: .shared))
        host.view.backgroundColor = .clear
        window.rootViewController = host
        window.isHidden = false
        self.window = window
    }

    func hide() {
        window?.isHidden = true
        window = nil
    }
}

private final class PassthroughWindow: UIWindow {
    /// The hosting view answers every point itself, so asking "was it the root view" let nothing through or took everything; the card's own frame is the one reliable answer.
    override func hitTest(_ point: CGPoint, with event: UIEvent?) -> UIView? {
        let frame = MainActor.assumeIsolated { InAppBanner.shared.cardFrame }
        guard frame.insetBy(dx: -6, dy: -6).contains(point) else { return nil }
        return super.hitTest(point, with: event)
    }
}
