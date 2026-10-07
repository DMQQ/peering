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
        didSet { openRequestedAt = openRequest == nil ? nil : Date() }
    }
    private var openRequestedAt: Date?
    /// What the person is reading now: news about it is not news.
    var onScreen: InAppBannerTarget? {
        didSet {
            if let onScreen, onScreen == current?.target { dismiss() }
        }
    }

    /// A request nobody took (the connection it waited for never came up) must not open a screen minutes later.
    var freshOpenRequest: InAppBannerTarget? {
        guard let openRequestedAt, Date().timeIntervalSince(openRequestedAt) < 60 else { return nil }
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
private struct LiquidDrop: Transition {
    func body(content: Content, phase: TransitionPhase) -> some View {
        content
            .scaleEffect(x: phase.isIdentity ? 1 : 0.45, y: phase.isIdentity ? 1 : 0.2, anchor: .top)
            .blur(radius: phase.isIdentity ? 0 : 14)
            .opacity(phase.isIdentity ? 1 : 0)
            .offset(y: phase.isIdentity ? 0 : -20)
    }
}

struct InAppBannerView: View {
    var banner: InAppBanner

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var drag: CGFloat = 0

    var body: some View {
        ZStack(alignment: .top) {
            Color.clear
            if let item = banner.current {
                card(item)
                    .padding(.horizontal, 12)
                    .padding(.top, 6)
                    .offset(y: rubber(drag))
                    .transition(reduceMotion ? AnyTransition.opacity : AnyTransition(LiquidDrop()))
                    .id(item.id)
            }
        }
    }

    /// Pulling down stretches with resistance; pulling up follows the finger.
    private func rubber(_ value: CGFloat) -> CGFloat {
        value > 0 ? 24 * (1 - exp(-value / 60)) : value
    }

    private func card(_ item: InAppBannerItem) -> some View {
        let expanded = banner.isExpanded
        let radius: CGFloat = expanded ? 30 : 28
        let shape = RoundedRectangle(cornerRadius: radius, style: .continuous)
        return VStack(alignment: .leading, spacing: 12) {
            header(item, expanded: expanded)
            if expanded {
                if let body = item.body, !body.isEmpty {
                    Text(body)
                        .font(.system(size: 12.5, design: item.asksApproval ? .monospaced : .default))
                        .foregroundStyle(.white.opacity(0.8))
                        .lineLimit(item.asksApproval ? 6 : 8)
                        .padding(10)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .background(.white.opacity(0.06), in: RoundedRectangle(cornerRadius: 14, style: .continuous))
                        .transition(.blurReplace)
                }
                actions(item)
                    .transition(.blurReplace)
            }
        }
        .padding(10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(ColorPalette.backdrop.opacity(0.97), in: shape)
        .overlay(shape.strokeBorder(.white.opacity(0.14)))
        .shadow(color: .black.opacity(0.5), radius: 20, y: 10)
        .contentShape(shape)
        .scaleEffect(drag > 0 ? 1 + min(drag, 80) / 1400 : 1, anchor: .top)
        .animation(InAppBanner.reshape, value: expanded)
        .onGeometryChange(for: CGRect.self) { $0.frame(in: .global) } action: { banner.cardFrame = $0 }
        // The card moves with the finger, so a local-space drag shrinks as it follows and the card oscillates.
        .simultaneousGesture(
            DragGesture(minimumDistance: 8, coordinateSpace: .global)
                .onChanged { drag = $0.translation.height }
                .onEnded { value in
                    let height = value.translation.height
                    let predicted = value.predictedEndTranslation.height
                    withAnimation(InAppBanner.reshape) { drag = 0 }
                    if height < -14 || predicted < -60 {
                        banner.dismiss()
                    } else if height > 14 || predicted > 60 {
                        banner.setExpanded(true)
                    } else {
                        banner.schedule()
                    }
                }
        )
        .sensoryFeedback(item.needsYou ? .warning : .success, trigger: item.id)
        .sensoryFeedback(.impact(flexibility: .soft), trigger: expanded)
    }

    private func header(_ item: InAppBannerItem, expanded: Bool) -> some View {
        HStack(spacing: 11) {
            Image(systemName: item.symbol)
                .font(.system(size: 15, weight: .semibold))
                .foregroundStyle(item.needsYou ? ColorPalette.caution : ColorPalette.ink)
                .symbolEffect(.bounce.up, options: .repeat(2), value: item.id)
                .frame(width: 38, height: 38)
                .background(.white.opacity(0.1), in: Circle())
            VStack(alignment: .leading, spacing: 2) {
                Text(item.title)
                    .font(.system(size: 14.5, weight: .semibold))
                    .foregroundStyle(ColorPalette.ink)
                    .lineLimit(1)
                Text(item.summary)
                    .font(.system(size: 12.5))
                    .foregroundStyle(.white.opacity(0.6))
                    .lineLimit(expanded ? 3 : 1)
            }
            Spacer(minLength: 4)
            Button {
                banner.setExpanded(!expanded)
            } label: {
                Image(systemName: "chevron.down")
                    .font(.system(size: 11, weight: .bold))
                    .foregroundStyle(.white.opacity(0.55))
                    .rotationEffect(.degrees(expanded ? 180 : 0))
                    .frame(width: 34, height: 34)
                    .background(.white.opacity(0.08), in: Circle())
                    .contentShape(Circle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel(expanded ? "Collapse" : "Expand")
        }
        .contentShape(Rectangle())
        .onTapGesture { banner.setExpanded(!expanded) }
    }

    @ViewBuilder
    private func actions(_ item: InAppBannerItem) -> some View {
        if item.asksApproval, item.options.isEmpty {
            HStack(spacing: 10) {
                pill("Deny", filled: false) { banner.answer(.deny) }
                pill("Allow", filled: true) { banner.answer(.allow) }
            }
        } else if item.asksApproval {
            VStack(spacing: 8) {
                ForEach(item.options, id: \.self) { label in
                    pill(LocalizedStringKey(label), filled: false) { banner.answer(.choose(label)) }
                }
            }
        } else {
            HStack(spacing: 10) {
                pill("Dismiss", filled: false) { banner.dismiss() }
                if item.target?.opensScreen == true {
                    pill(item.openLabel, filled: true) { banner.open() }
                }
            }
        }
    }

    private func pill(_ label: LocalizedStringKey, filled: Bool, run: @escaping () -> Void) -> some View {
        Button(action: run) {
            Text(label)
                .font(.system(size: 14.5, weight: .semibold))
                .foregroundStyle(filled ? ColorPalette.onInk : .white)
                .frame(maxWidth: .infinity)
                .frame(height: 42)
                .background {
                    if filled {
                        Capsule().fill(ColorPalette.ink)
                    } else {
                        Capsule().fill(.white.opacity(0.12))
                    }
                }
                .contentShape(Capsule())
        }
        .buttonStyle(SpringPressStyle())
    }
}

private struct SpringPressStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .scaleEffect(configuration.isPressed ? 0.93 : 1)
            .animation(.spring(response: 0.25, dampingFraction: 0.5), value: configuration.isPressed)
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
