import Foundation
import PeeringKit
import RemoteCore
import SwiftUI

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
