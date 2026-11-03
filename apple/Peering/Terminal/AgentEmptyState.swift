import Foundation
import PeeringKit
import RemoteCore
import SwiftUI

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
