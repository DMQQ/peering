import MacCastKit
import RemoteCore
import SwiftUI

enum AgentSuggestions {
    static let all: [(symbol: String, text: String, detail: String)] = [
        ("doc.text.magnifyingglass", String(localized: "What does this project do?"), String(localized: "A tour of how it is laid out")),
        ("checkmark.seal", String(localized: "Fix the failing tests"), String(localized: "Run them, find the cause, patch it")),
        ("arrow.triangle.branch", String(localized: "Review the latest changes"), String(localized: "Read the diff and flag what looks wrong")),
    ]
}

/// A new chat before its first message: who is on the other end, where it works, and three ways to begin.
struct AgentEmptyChat: View {
    let agent: TerminalAgent?
    let session: RemoteAgentSession
    /// The keyboard is up: the suggestions step aside so the rest still fits above the composer.
    var compact = false
    let pick: (String) -> Void

    @State private var arrived = false
    @State var templates = PromptTemplates.load()
    @State var addingTemplate = false
    @State var templateDraft = ""
    @AppStorage("Peering.chatGuideSeen") private var guideSeen = false
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    private var ended: Bool { session.state == .exited || session.state == .failed }

    var body: some View {
        GeometryReader { geometry in
            ScrollView {
                content
                    .frame(minHeight: geometry.size.height)
            }
            .scrollBounceBehavior(.basedOnSize)
            .scrollDismissesKeyboard(.interactively)
        }
        .background(alignment: .top) { aurora }
        .onAppear { arrived = true }
        .alert("Save a prompt", isPresented: $addingTemplate) {
            TextField("What should the agent do?", text: $templateDraft)
            Button("Save") { saveTemplate() }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("It appears with the suggestions in every new chat.")
        }
    }

    private var content: some View {
        VStack(spacing: 0) {
            Spacer(minLength: 8)
            tile
                .modifier(Rise(arrived: arrived, order: 0))
            Text(ended ? "This chat has ended" : "What are we working on?")
                .font(DisplayFont.display(30))
                .tracking(-0.9)
                .multilineTextAlignment(.center)
                .foregroundStyle(ColorPalette.ink)
                .padding(.top, 8)
                .modifier(Rise(arrived: arrived, order: 1))
            if ended {
                Text("This chat has ended. Its conversation is above; start a new chat to keep going.")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                    .padding(.top, 14)
                    .padding(.horizontal, 12)
                    .modifier(Rise(arrived: arrived, order: 3))
            }
            Spacer(minLength: 20)
            if !ended, !compact, !guideSeen {
                HubGuideCard.chat { withAnimation(Motion.settle) { guideSeen = true } }
                    .padding(.bottom, 10)
                    .modifier(Rise(arrived: arrived, order: 4))
            }
            if !ended, !compact {
                VStack(spacing: 8) {
                    ForEach(Array(AgentSuggestions.all.enumerated()), id: \.offset) { offset, suggestion in
                        row(suggestion)
                            .modifier(Rise(arrived: arrived, order: 4 + offset))
                    }
                    templateRows
                        .modifier(Rise(arrived: arrived, order: 7))
                }
                .padding(.bottom, 10)
                .transition(.opacity.combined(with: .scale(scale: 0.96, anchor: .bottom)))
            }
        }
        .frame(maxWidth: .infinity)
        .padding(.horizontal, 16)
        .animation(.spring(response: 0.4, dampingFraction: 0.8), value: compact)
    }

    /// Two blurred lights drifting behind the tile: the screen is never a still frame, and never louder than a glow.
    private var aurora: some View {
        TimelineView(.animation(minimumInterval: 1.0 / 20.0, paused: reduceMotion)) { context in
            let t = reduceMotion ? 0 : context.date.timeIntervalSinceReferenceDate
            ZStack {
                Circle()
                    .fill(Color.white.opacity(0.13))
                    .frame(width: 240, height: 240)
                    .offset(x: sin(t * 0.35) * 60, y: cos(t * 0.27) * 26)
                Circle()
                    .fill(Color.white.opacity(0.10))
                    .frame(width: 180, height: 180)
                    .offset(x: cos(t * 0.31) * 80, y: sin(t * 0.4) * 30 + 30)
            }
            .blur(radius: 70)
            .frame(height: 320)
            .offset(y: 30)
            .opacity(arrived ? 1 : 0)
            .animation(.easeOut(duration: 1.4), value: arrived)
        }
        .allowsHitTesting(false)
        .ignoresSafeArea(.container)
    }

    private var tile: some View {
        ZStack {
            LiveTimeline { context in
                let t = reduceMotion ? 0 : context.date.timeIntervalSinceReferenceDate
                ZStack {
                    ForEach(0..<2, id: \.self) { ring in
                        let phase = reduceMotion ? 0.5 : (t / 3.6 + Double(ring) * 0.5).truncatingRemainder(dividingBy: 1)
                        RoundedRectangle(cornerRadius: 28 + 22 * phase, style: .continuous)
                            .strokeBorder(Color.white.opacity(0.4 * (1 - phase)), lineWidth: 1)
                            .frame(width: 88 + 72 * phase, height: 88 + 72 * phase)
                    }
                    Circle()
                        .fill(.white)
                        .frame(width: 5, height: 5)
                        .shadow(color: ColorPalette.ink, radius: 6)
                        .offset(x: 66 * cos(t * 0.9), y: 66 * sin(t * 0.9) * 0.55)
                }
            }
            Image(systemName: agent?.symbol ?? "sparkles")
                .font(.system(size: 34, weight: .medium))
                .foregroundStyle(ColorPalette.ink)
                .symbolEffect(.breathe, isActive: !reduceMotion)
                .frame(width: 88, height: 88)
                .background {
                    RoundedRectangle(cornerRadius: 28, style: .continuous)
                        .fill(Color.white.opacity(0.14))
                }
                .overlay {
                    RoundedRectangle(cornerRadius: 28, style: .continuous)
                        .strokeBorder(
                            LinearGradient(colors: [Color.white.opacity(0.55), Color.white.opacity(0.1)], startPoint: .top, endPoint: .bottom)
                        )
                }
                .modifier(AgentIdleFloat())
        }
        .scaleEffect(0.8)
        .frame(height: 100)
    }

    func row(_ suggestion: (symbol: String, text: String, detail: String)) -> some View {
        Button { pick(suggestion.text) } label: {
            HStack(spacing: 12) {
                Image(systemName: suggestion.symbol)
                    .font(.system(size: 13, weight: .medium))
                    .foregroundStyle(ColorPalette.ink)
                    .frame(width: 34, height: 34)
                    .background(Color.white.opacity(0.14), in: RoundedRectangle(cornerRadius: 10, style: .continuous))
                VStack(alignment: .leading, spacing: 2) {
                    Text(suggestion.text)
                        .font(.system(size: 14.5, weight: .semibold))
                        .foregroundStyle(ColorPalette.ink)
                        .lineLimit(1)
                    Text(suggestion.detail)
                        .font(.system(size: 12))
                        .foregroundStyle(.white.opacity(0.5))
                        .lineLimit(1)
                }
                Spacer(minLength: 6)
                Image(systemName: "arrow.up.left")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(.white.opacity(0.35))
            }
            .padding(.horizontal, 12)
            .frame(height: 62)
            .frame(maxWidth: .infinity)
            .overlay {
                RoundedRectangle(cornerRadius: 16, style: .continuous)
                    .strokeBorder(
                        LinearGradient(colors: [.white.opacity(0.16), .white.opacity(0.05)], startPoint: .top, endPoint: .bottom)
                    )
            }
            .contentShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
        }
        .buttonStyle(AgentRowPress())
    }
}

private struct AgentRowPress: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .scaleEffect(configuration.isPressed ? 0.97 : 1)
            .opacity(configuration.isPressed ? 0.8 : 1)
            .animation(.spring(response: 0.28, dampingFraction: 0.55), value: configuration.isPressed)
    }
}

/// Each piece arrives on its own delay, rising from below with a little overshoot.
private struct Rise: ViewModifier {
    let arrived: Bool
    let order: Int

    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    func body(content: Content) -> some View {
        content
            .opacity(arrived ? 1 : 0)
            .offset(y: arrived || reduceMotion ? 0 : 22)
            .scaleEffect(arrived || reduceMotion ? 1 : 0.94)
            .animation(
                reduceMotion ? .none : .spring(response: 0.55, dampingFraction: 0.72).delay(0.05 + Double(order) * 0.06),
                value: arrived
            )
    }
}
