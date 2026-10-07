import SwiftUI

struct AgentCardStatus: Equatable {
    var working = 0
    var needsYou = 0
    var chats = 0
    var lastUsed: String
}

/// One agent on the Mac terminals page: who it is and what it is doing right now. Tapping selects it; the dock at the bottom acts on the selection.
struct AgentHubCard: View {
    let agent: TerminalAgent
    let status: AgentCardStatus
    let index: Int
    let isSelected: Bool
    let select: () -> Void
    /// Set when the card is the closed selector: the mark at its end says it opens a list, with the direction it will go.
    var opens: Bool?

    @State private var arrived: Bool
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    init(agent: TerminalAgent, status: AgentCardStatus, index: Int, isSelected: Bool, opens: Bool? = nil, select: @escaping () -> Void) {
        self.agent = agent
        self.status = status
        self.index = index
        self.isSelected = isSelected
        self.select = select
        self.opens = opens
        _arrived = State(initialValue: ArrivalMemory.seen.contains("agent|" + agent.id))
    }

    private var isBusy: Bool { status.working > 0 }

    var body: some View {
        Button(action: select) {
            HStack(spacing: 13) {
                tile
                VStack(alignment: .leading, spacing: 4) {
                    Text(verbatim: agent.name)
                        .font(DisplayFont.display(19))
                        .tracking(-0.4)
                        .foregroundStyle(ColorPalette.ink)
                        .lineLimit(1)
                    statusLine
                        .font(.caption)
                }
                Spacer(minLength: 0)
                if let opens {
                    Image(systemName: "chevron.down")
                        .font(.system(size: 13, weight: .bold))
                        .foregroundStyle(.white.opacity(0.55))
                        .rotationEffect(.degrees(opens ? 180 : 0))
                        .frame(width: 30, height: 30)
                        .background(.white.opacity(0.08), in: Circle())
                } else {
                    Image(systemName: isSelected ? "checkmark.circle.fill" : "circle")
                        .font(.system(size: 20))
                        .foregroundStyle(isSelected ? ColorPalette.ink : .white.opacity(0.25))
                        .contentTransition(.symbolEffect(.replace))
                        .symbolEffect(.bounce, value: isSelected)
                }
            }
            .padding(14)
            .frame(maxWidth: .infinity, alignment: .leading)
            .overlay {
                RoundedRectangle(cornerRadius: 22, style: .continuous)
                    .strokeBorder(
                        isSelected
                            ? AnyShapeStyle(.white.opacity(0.6))
                            : AnyShapeStyle(LinearGradient(colors: [.white.opacity(0.18), .white.opacity(0.05)], startPoint: .top, endPoint: .bottom)),
                        lineWidth: isSelected ? 1.5 : 1
                    )
            }
            .runningEdge(isBusy, radius: 22)
            .contentShape(RoundedRectangle(cornerRadius: 22, style: .continuous))
        }
        .buttonStyle(CardPress())
        .opacity(arrived ? 1 : 0)
        .offset(y: arrived || reduceMotion ? 0 : 26)
        .scaleEffect(arrived || reduceMotion ? 1 : 0.95)
        .animation(
            reduceMotion ? .none : .spring(response: 0.55, dampingFraction: 0.7).delay(0.04 + Double(index) * 0.07),
            value: arrived
        )
        .animation(.spring(response: 0.38, dampingFraction: 0.66), value: isSelected)
        .animation(Motion.settle, value: status)
        .onAppear {
            ArrivalMemory.seen.insert("agent|" + agent.id)
            arrived = true
        }
        .accessibilityAddTraits(isSelected ? .isSelected : [])
    }

    private var tile: some View {
        ZStack {
            if isBusy, !reduceMotion {
                LiveTimeline { context in
                    let phase = (context.date.timeIntervalSinceReferenceDate / 1.6).truncatingRemainder(dividingBy: 1)
                    RoundedRectangle(cornerRadius: 17 + 8 * phase, style: .continuous)
                        .strokeBorder(.white.opacity(0.4 * (1 - phase)), lineWidth: 1.2)
                        .frame(width: 50 + 18 * phase, height: 50 + 18 * phase)
                }
            }
            Image(systemName: agent.symbol)
                .font(.system(size: 20, weight: .medium))
                .foregroundStyle(ColorPalette.ink)
                .frame(width: 50, height: 50)
                .background(.white.opacity(0.12), in: RoundedRectangle(cornerRadius: 15, style: .continuous))
                .symbolEffect(.pulse, isActive: isBusy)
        }
        .frame(width: 50, height: 50)
    }

    @ViewBuilder
    private var statusLine: some View {
        if status.needsYou > 0 {
            Label("\(status.needsYou) waiting on you", systemImage: "hand.raised.fill")
                .foregroundStyle(ColorPalette.caution)
                .symbolEffect(.pulse)
        } else if status.working > 0 {
            Label("\(status.working) working", systemImage: "circle.fill")
                .foregroundStyle(.white.opacity(0.85))
                .symbolEffect(.pulse)
        } else if status.chats > 0 {
            Text("\(status.chats) open · \(status.lastUsed)")
                .foregroundStyle(.secondary)
        } else {
            Text(verbatim: status.lastUsed)
                .foregroundStyle(.secondary)
        }
    }
}

/// The terminals tab's bar: files, and a new shell.
struct TerminalDock<Gate: View>: View {
    let offersFiles: Bool
    let files: () -> Void
    @ViewBuilder let gate: (_ button: AnyView) -> Gate
    let newTerminal: () -> Void

    var body: some View {
        HStack(spacing: 8) {
            if offersFiles {
                DockIconButton(symbol: "folder", title: "Files", action: files)
                    .accessibilityLabel("This Mac's files")
            }
            gate(AnyView(
                Button(action: newTerminal) {
                    HStack(spacing: 10) {
                        Image(systemName: "plus")
                            .font(.system(size: 14, weight: .bold))
                            .foregroundStyle(ColorPalette.ink)
                            .frame(width: 32, height: 32)
                            .background(ColorPalette.onInk, in: Circle())
                        Text("New terminal")
                            .font(.system(size: 15.5, weight: .semibold))
                    }
                    .foregroundStyle(ColorPalette.onInk)
                    .frame(maxWidth: .infinity)
                    .frame(height: 48)
                    .background(Capsule().fill(ColorPalette.ink))
                    .contentShape(Capsule())
                }
                .buttonStyle(CardPress())
                .accessibilityLabel("New terminal")
            ))
            .frame(maxWidth: .infinity)
        }
        .padding(7)
        .dockSurface()
        .shadow(color: .black.opacity(0.4), radius: 16, y: 6)
        .padding(.horizontal, 16)
        .padding(.bottom, 6)
    }
}

/// The floating bar at the bottom: files always, and Chat and Terminal for the selected agent.
struct AgentDock: View {
    let agent: TerminalAgent?
    let agentCount: Int
    let openPicker: () -> Void
    let canChat: Bool
    let offersFiles: Bool
    let files: () -> Void
    let chat: () -> Void
    let terminal: () -> Void

    @State private var held = false

    var body: some View {
        HStack(spacing: 8) {
            if offersFiles {
                DockIconButton(symbol: "folder", title: "Files", action: files)
                    .accessibilityLabel("This Mac's files")
                .accessibilityIdentifier("files-row")
            }
            if agent == nil, agentCount > 0 {
                Button(action: openPicker) {
                    primary("Choose an agent", symbol: "sparkles", id: "none")
                }
                .buttonStyle(CardPress())
                .frame(maxWidth: .infinity)
                .transition(.blurReplace)
            }
            if let agent {
                if canChat {
                    holdsToChoose(chat) {
                        primary("Chat with \(agent.name)", symbol: agent.symbol, id: agent.id)
                    }
                    .accessibilityLabel(Text("Chat with \(agent.name)"))
                    .frame(maxWidth: .infinity)
                    .transition(.blurReplace)
                    DockIconButton(symbol: "terminal", title: "Terminal", action: terminal)
                        .accessibilityLabel(Text("Start \(agent.name)"))
                    .transition(.blurReplace)
                } else {
                    holdsToChoose(terminal) {
                        primary("Open \(agent.name)", symbol: agent.symbol, id: agent.id)
                    }
                    .accessibilityLabel(Text("Start \(agent.name)"))
                    .frame(maxWidth: .infinity)
                    .transition(.blurReplace)
                }
            }
        }
        .padding(7)
        .dockSurface()
        .shadow(color: .black.opacity(0.4), radius: 16, y: 6)
        .padding(.horizontal, 16)
        .padding(.bottom, 6)
        .animation(Motion.settle, value: canChat)
        .animation(Motion.settle, value: agent?.id == nil)
    }

    /// The choice of agent lives in the bar it steers, so the page above is not spent on a list that is used once.
    /// Holding the main button reopens the choice, so the bar carries one control for it rather than two.
    private func holdsToChoose<Label: View>(_ run: @escaping () -> Void, @ViewBuilder label: () -> Label) -> some View {
        Button {
            if held { held = false } else { run() }
        } label: {
            label()
        }
        .buttonStyle(CardPress())
        .simultaneousGesture(
            LongPressGesture(minimumDuration: 0.4).onEnded { _ in
                guard agentCount > 1 else { return }
                held = true
                openPicker()
            }
        )
        .sensoryFeedback(.impact(flexibility: .soft), trigger: held)
        .accessibilityAction(named: Text("Choose the agent")) { openPicker() }
    }

    /// The agent's own mark sits in the button, so the bar reads as being about this agent and changes with the selection.
    private func primary(_ title: LocalizedStringKey, symbol: String, id: String) -> some View {
        HStack(spacing: 10) {
            Image(systemName: symbol)
                .font(.system(size: 14, weight: .semibold))
                .foregroundStyle(ColorPalette.ink)
                .frame(width: 32, height: 32)
                .background(ColorPalette.onInk, in: Circle())
                .contentTransition(.symbolEffect(.replace))
            Text(title)
                .font(.system(size: 15.5, weight: .semibold))
                .lineLimit(1)
                .minimumScaleFactor(0.8)
                .contentTransition(.opacity)
        }
        .foregroundStyle(ColorPalette.onInk)
        .padding(.leading, 8)
        .padding(.trailing, 14)
        .frame(maxWidth: .infinity)
        .frame(height: 48)
        .background(Capsule().fill(ColorPalette.ink))
        .contentShape(Capsule())
        .animation(Motion.settle, value: id)
    }
}

/// An icon with a word under it: a folder or a prompt glyph alone can mean several things to someone new.
private struct DockIconButton: View {
    let symbol: String
    let title: LocalizedStringKey
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            VStack(spacing: 2) {
                Image(systemName: symbol)
                    .font(.system(size: 16, weight: .semibold))
                Text(title)
                    .font(.system(size: 10, weight: .medium))
                    .lineLimit(1)
                    .minimumScaleFactor(0.8)
            }
            .foregroundStyle(.white)
            .frame(width: 58, height: 48)
            .glassSurface(in: Capsule(), interactive: true)
            .contentShape(Capsule())
        }
        .buttonStyle(CardPress())
    }
}

private struct CardPress: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .scaleEffect(configuration.isPressed ? 0.95 : 1)
            .opacity(configuration.isPressed ? 0.9 : 1)
            .animation(.spring(response: 0.26, dampingFraction: 0.52), value: configuration.isPressed)
    }
}

extension View {
    /// A solid pill, not glass: glass re-samples what is behind it every frame, and behind this bar the page fades on each tab switch.
    fileprivate func dockSurface() -> some View {
        background(ColorPalette.backdrop.opacity(0.96), in: Capsule())
            .overlay(Capsule().strokeBorder(.white.opacity(0.14)))
    }
}
