import MacCastKit
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

/// The floating bar at the bottom, one view for both tabs so a switch changes the pill's words and mark and the buttons around it come and go, instead of one bar replacing another.
/// Agents: Chat (or Open) for the selected agent, and CLI. Terminals: Files, and a new shell.
struct HubDock: View {
    let tab: HubTab
    let agent: TerminalAgent?
    let agentCount: Int
    let openPicker: () -> Void
    let canChat: Bool
    let chat: () -> Void
    let terminal: () -> Void
    let offersFiles: Bool
    let files: () -> Void
    let canOpenAnotherShell: Bool
    let newTerminal: () -> Void

    @State private var held = false

    var body: some View {
        HStack(spacing: 8) {
            if tab == .terminals, offersFiles {
                DockIconButton(symbol: "folder", title: "Files", action: files)
                    .accessibilityLabel("This Mac's files")
                    .transition(.blurReplace)
            }
            main
                .frame(maxWidth: .infinity)
            if tab == .agents, canChat, let agent {
                DockIconButton(symbol: "terminal", title: "CLI", action: terminal)
                    .accessibilityLabel(Text("Start \(agent.name)"))
                    .transition(.blurReplace)
            }
        }
        .padding(.horizontal, 16)
        .padding(.top, 8)
        .padding(.bottom, 6)
        .animation(Motion.settle, value: tab)
        .animation(Motion.settle, value: canChat)
    }

    @ViewBuilder
    private var main: some View {
        if tab == .terminals {
            PlanLocked(
                capability: .shellTabs,
                title: String(localized: "New terminal"),
                diameter: 26,
                isIncluded: canOpenAnotherShell
            ) {
                Button(action: newTerminal) {
                    primary("New terminal", symbol: "plus", id: "terminal")
                }
                .buttonStyle(CardPress())
                .accessibilityLabel("New terminal")
            }
        } else if let agent {
            holdsToChoose(canChat ? chat : terminal) {
                primary(canChat ? "Chat with \(agent.name)" : "Open \(agent.name)", symbol: agent.symbol, id: agent.id)
            }
            .accessibilityLabel(Text(canChat ? "Chat with \(agent.name)" : "Start \(agent.name)"))
        } else if agentCount > 0 {
            Button(action: openPicker) {
                primary("Choose an agent", symbol: "sparkles", id: "none")
            }
            .buttonStyle(CardPress())
        }
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

    /// The mark sits in the button, so the bar reads as being about this agent (or the new shell) and changes with the selection.
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
