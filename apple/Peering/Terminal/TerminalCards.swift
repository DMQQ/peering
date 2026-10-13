import Foundation
import PeeringKit
import RemoteCore
import SwiftUI

/// The folder each shell was opened in from this phone. Nothing on the wire says where a shell is now, so this is where it started, and a `cd` typed later is not seen.
enum TerminalFolders {
    private static let key = "Peering.terminalFolders"

    static func record(_ path: String, for id: UUID) {
        var all = UserDefaults.standard.dictionary(forKey: key) as? [String: String] ?? [:]
        all[id.uuidString] = path
        UserDefaults.standard.set(all, forKey: key)
    }

    static func folder(for id: UUID) -> String? {
        (UserDefaults.standard.dictionary(forKey: key) as? [String: String])?[id.uuidString]
    }

    /// `/Users/anyone/Projects` as `~/Projects`, the way a prompt writes it.
    static func shortened(_ path: String) -> String {
        let parts = path.split(separator: "/", omittingEmptySubsequences: true)
        guard parts.count >= 2, parts[0] == "Users" else { return path }
        let rest = parts.dropFirst(2).joined(separator: "/")
        return rest.isEmpty ? "~" : "~/" + rest
    }
}

/// What a terminal card needs, rebuilt a couple of times a second. The terminals themselves carry their whole output and change with every chunk, which made a list that read them redraw on each one: see ``AgentCardDigest``.
struct TerminalCardDigest: Identifiable, Equatable {
    let id: UUID
    let name: String
    let state: TerminalState
    let isRunning: Bool
    let createdAt: Date?
    let lines: [String]
    /// More of the screen than a card shows, for the long-press peek.
    let peekLines: [String]
    let folder: String?

    init(_ terminal: RemoteTerminal) {
        id = terminal.id
        name = terminal.name
        state = terminal.state
        isRunning = terminal.isRunning
        createdAt = terminal.createdAt
        lines = terminal.isRunning ? Self.tail(of: terminal, count: 4) : []
        peekLines = terminal.isRunning ? Self.tail(of: terminal, count: 24) : []
        folder = TerminalFolders.folder(for: terminal.id).map(TerminalFolders.shortened)
    }

    /// The last few lines that say something, clipped to what a card can hold.
    private static func tail(of terminal: RemoteTerminal, count: Int) -> [String] {
        terminal.screen.visible
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
            .suffix(count)
            .map { String($0.prefix(90)) }
    }
}

extension SessionModel {
    var terminalCards: [TerminalCardDigest] { activeSession?.terminalCards ?? [] }
}

/// A shell as a small window onto the Mac: its name and age on a title bar, its last lines underneath, and a cursor that breathes while it runs.
struct TerminalWindowCard: View {
    let terminal: TerminalCardDigest
    let index: Int
    /// The Mac it runs on. The wire carries no folder, so the machine is what can be said for certain.
    var host: String?

    @State private var arrived: Bool
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    init(terminal: TerminalCardDigest, index: Int, host: String? = nil) {
        self.terminal = terminal
        self.index = index
        self.host = host
        _arrived = State(initialValue: ArrivalMemory.seen.contains("terminal|\(terminal.id)"))
    }

    private var needsYou: Bool {
        if case .attention = terminal.state { return true }
        return false
    }

    var body: some View {
        VStack(spacing: 0) {
            titleBar
            Rectangle().fill(.white.opacity(0.08)).frame(height: 1)
            screen
        }
        .frame(maxWidth: .infinity)
        .clipShape(RoundedRectangle(cornerRadius: 20, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 20, style: .continuous)
                .strokeBorder(
                    LinearGradient(colors: [.white.opacity(0.2), .white.opacity(0.06)], startPoint: .top, endPoint: .bottom)
                )
        }
        .contentShape(RoundedRectangle(cornerRadius: 20, style: .continuous))
        .opacity(arrived ? 1 : 0)
        .offset(y: arrived || reduceMotion ? 0 : 22)
        .scaleEffect(arrived || reduceMotion ? 1 : 0.96)
        .animation(
            reduceMotion ? .none : .spring(response: 0.5, dampingFraction: 0.72).delay(0.03 + Double(min(index, 6)) * 0.06),
            value: arrived
        )
        .animation(Motion.settle, value: terminal.lines)
        .onAppear {
            ArrivalMemory.seen.insert("terminal|\(terminal.id)")
            arrived = true
        }
    }

    private var titleBar: some View {
        HStack(spacing: 10) {
            HStack(spacing: 5) {
                ForEach(0..<3, id: \.self) { _ in
                    Circle().fill(.white.opacity(0.16)).frame(width: 8, height: 8)
                }
            }
            VStack(alignment: .leading, spacing: 1) {
                Text(verbatim: terminal.name)
                    .font(.system(size: 13.5, weight: .semibold))
                    .foregroundStyle(ColorPalette.ink)
                    .lineLimit(1)
                    .truncationMode(.middle)
                if let folder = terminal.folder {
                    Text(verbatim: folder)
                        .font(.system(size: 10.5, design: .monospaced))
                        .foregroundStyle(.white.opacity(0.5))
                        .lineLimit(1)
                        .truncationMode(.head)
                } else if let host {
                    Label {
                        Text("on \(host)")
                    } icon: {
                        Image(systemName: "laptopcomputer")
                    }
                    .font(.system(size: 10.5))
                    .foregroundStyle(.white.opacity(0.45))
                    .lineLimit(1)
                    .labelStyle(.titleAndIcon)
                }
            }
            Spacer(minLength: 6)
            statusLabel
            Image(systemName: "chevron.right")
                .font(.system(size: 10, weight: .bold))
                .foregroundStyle(.white.opacity(0.3))
        }
        .padding(.horizontal, 14)
        .frame(height: 46)
        .background(.white.opacity(0.04))
    }

    @ViewBuilder
    private var statusLabel: some View {
        switch terminal.state {
        case .starting:
            Text("Starting").font(.caption).foregroundStyle(.secondary)
        case .running:
            TimelineView(.periodic(from: .now, by: 60)) { _ in
                HStack(spacing: 5) {
                    Circle().fill(Color.green).frame(width: 6, height: 6)
                    Text(verbatim: Self.age(of: terminal.createdAt)).font(.system(size: 11.5, design: .monospaced))
                }
                .foregroundStyle(.white.opacity(0.6))
            }
        case .attention(let kind):
            Label(kind == .password ? "Password" : "Confirm", systemImage: "hand.raised.fill")
                .font(.system(size: 11.5, weight: .semibold))
                .foregroundStyle(ColorPalette.caution)
                .symbolEffect(.pulse)
        case .failed:
            Text("Failed").font(.system(size: 11.5, weight: .semibold)).foregroundStyle(ColorPalette.danger)
        case .stopped:
            Text("Exited").font(.caption).foregroundStyle(.secondary)
        }
    }

    private var screen: some View {
        VStack(alignment: .leading, spacing: 3) {
            if terminal.lines.isEmpty {
                Text(verbatim: terminal.isRunning ? "" : String(localized: "Nothing running"))
                    .font(.system(size: 11.5, design: .monospaced))
                    .foregroundStyle(.white.opacity(0.35))
            }
            ForEach(Array(terminal.lines.enumerated()), id: \.offset) { offset, line in
                HStack(spacing: 0) {
                    Text(verbatim: line)
                        .font(.system(size: 11.5, design: .monospaced))
                        .foregroundStyle(.white.opacity(offset == terminal.lines.count - 1 ? 0.85 : 0.5))
                        .lineLimit(1)
                        .truncationMode(.tail)
                    if offset == terminal.lines.count - 1, terminal.isRunning {
                        Cursor()
                    }
                }
            }
            if terminal.lines.isEmpty, terminal.isRunning {
                Cursor()
            }
        }
        .frame(maxWidth: .infinity, minHeight: 74, alignment: .topLeading)
        .padding(.horizontal, 14)
        .padding(.vertical, 11)
        .background(.black.opacity(0.35))
    }

    static func age(of date: Date?) -> String {
        guard let date else { return String(localized: "Running") }
        let seconds = Date.now.timeIntervalSince(date)
        if seconds < 60 { return String(localized: "now") }
        return TerminalCommandFinishDetector.spokenDuration(seconds)
    }
}

/// A block that blinks at the speed a terminal's does.
private struct Cursor: View {
    var body: some View {
        LiveTimeline { context in
            let on = Int(context.date.timeIntervalSinceReferenceDate * 1.8) % 2 == 0
            Rectangle()
                .fill(.white.opacity(on ? 0.8 : 0))
                .frame(width: 6, height: 12)
                .padding(.leading, 3)
        }
    }
}

/// No shells yet: a window that types a few commands to itself, so the page shows what it is for.
struct TerminalEmptyState: View {
    let create: () -> Void

    private static let script = ["swift test", "git status", "npm run dev", "claude", "tail -f server.log"]

    var body: some View {
        VStack(spacing: 22) {
            window
            VStack(spacing: 6) {
                Text("No terminals yet")
                    .font(DisplayFont.display(24))
                    .tracking(-0.6)
                    .foregroundStyle(ColorPalette.ink)
                Text("A real shell on your Mac, driven from here. It keeps running when you disconnect.")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                    .padding(.horizontal, 10)
            }
        }
        .frame(maxWidth: .infinity)
        .padding(.top, 14)
    }

    private var window: some View {
        VStack(spacing: 0) {
            HStack(spacing: 5) {
                ForEach(0..<3, id: \.self) { _ in Circle().fill(.white.opacity(0.16)).frame(width: 8, height: 8) }
                Spacer()
            }
            .padding(.horizontal, 14)
            .frame(height: 38)
            .background(.white.opacity(0.04))
            Rectangle().fill(.white.opacity(0.08)).frame(height: 1)
            LiveTimeline { context in
                Text(verbatim: typed(at: context.date.timeIntervalSinceReferenceDate))
                    .font(.system(size: 14, design: .monospaced))
                    .foregroundStyle(.white.opacity(0.85))
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            .padding(16)
            .frame(height: 74, alignment: .topLeading)
            .background(.black.opacity(0.35))
        }
        .clipShape(RoundedRectangle(cornerRadius: 20, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 20, style: .continuous)
                .strokeBorder(LinearGradient(colors: [.white.opacity(0.2), .white.opacity(0.06)], startPoint: .top, endPoint: .bottom))
        }
        .modifier(AgentIdleFloat())
    }

    /// Types one command a character at a time, holds it, then wipes it and starts the next.
    private func typed(at time: TimeInterval) -> String {
        let perCommand = 4.2
        let slot = Int(time / perCommand)
        let local = time.truncatingRemainder(dividingBy: perCommand)
        let command = Self.script[slot % Self.script.count]
        let count = min(command.count, Int(local / 0.07))
        let blink = Int(time * 2) % 2 == 0
        let shown = (count < command.count || local < perCommand - 0.6) ? String(command.prefix(count)) : ""
        return "$ " + shown + (blink ? "▌" : " ")
    }
}

/// No chats yet: a conversation that asks itself a few things and gets a reply drawn in, so the page shows what it is for.
struct AgentEmptyState: View {
    private static let script = [
        String(localized: "What does this project do?"),
        String(localized: "Fix the failing test"),
        String(localized: "Explain this stack trace"),
        String(localized: "Add a dark mode toggle"),
    ]
    private static let cycle = 6.4

    var body: some View {
        VStack(spacing: 22) {
            conversation
            VStack(spacing: 6) {
                Text("No chats yet")
                    .font(DisplayFont.display(24))
                    .tracking(-0.6)
                    .foregroundStyle(ColorPalette.ink)
                Text("Pick an agent below and talk to it. It works on your Mac, and the chat stays here when you leave.")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                    .padding(.horizontal, 10)
            }
        }
        .frame(maxWidth: .infinity)
        .padding(.top, 14)
    }

    private var conversation: some View {
        LiveTimeline { context in
            let time = context.date.timeIntervalSinceReferenceDate
            let slot = Int(time / Self.cycle)
            let local = time.truncatingRemainder(dividingBy: Self.cycle)
            let prompt = Self.script[slot % Self.script.count]
            let typed = min(prompt.count, Int(local / 0.05))
            let reply = max(0, min(1, (local - 2.4) / 0.5))
            let fade = local > Self.cycle - 0.5 ? max(0, (Self.cycle - local) / 0.5) : 1

            VStack(alignment: .leading, spacing: 14) {
                HStack {
                    Spacer(minLength: 36)
                    Text(verbatim: String(prompt.prefix(typed)) + (typed < prompt.count ? "▌" : ""))
                        .font(.system(size: 13.5))
                        .foregroundStyle(.white.opacity(0.9))
                        .padding(.horizontal, 12)
                        .padding(.vertical, 9)
                        .background {
                            RoundedRectangle(cornerRadius: 14, style: .continuous)
                                .fill(LinearGradient(colors: [.white.opacity(0.09), .white.opacity(0.045)], startPoint: .top, endPoint: .bottom))
                        }
                        .overlay { RoundedRectangle(cornerRadius: 14, style: .continuous).strokeBorder(.white.opacity(0.07)) }
                        .opacity(typed == 0 ? 0 : 1)
                }
                .frame(height: 38)
                HStack(alignment: .top, spacing: 10) {
                    IconTile(symbol: "sparkles", size: 30)
                    VStack(alignment: .leading, spacing: 8) {
                        ForEach(Array([0.92, 0.7, 0.45].enumerated()), id: \.offset) { index, width in
                            let progress = max(0, min(1, reply * 3 - Double(index)))
                            GeometryReader { geometry in
                                Capsule()
                                    .fill(.white.opacity(0.14))
                                    .frame(width: geometry.size.width * width * progress, height: 7)
                            }
                            .frame(height: 7)
                        }
                    }
                    .padding(.top, 6)
                }
                .opacity(reply > 0 ? 1 : 0.35)
            }
            .padding(16)
            .frame(maxWidth: .infinity, alignment: .leading)
            .opacity(fade)
        }
        .frame(height: 140)
        .overlay {
            RoundedRectangle(cornerRadius: 20, style: .continuous)
                .strokeBorder(LinearGradient(colors: [.white.opacity(0.2), .white.opacity(0.06)], startPoint: .top, endPoint: .bottom))
        }
        .modifier(AgentIdleFloat())
        .accessibilityHidden(true)
    }
}
