import PeeringKit
import RemoteCore
import SwiftUI

/// How much of the model's context this chat has used ("70k / 1M") and, beside it, how much of the account's five-hour window is spent. Plain white until either is nearly full, then full brightness, since the palette has no warning hue.
struct AgentContextBar: View {
    let usage: AgentUsage
    let showsUsage: () -> Void

    private var contextFraction: Double? {
        AgentContextMeter.fraction(used: usage.contextUsedTokens, window: usage.contextWindowTokens)
    }

    private var fiveHour: AgentUsageLimit? { AgentContextMeter.fiveHour(in: usage.limits) }

    /// Whether there is anything to draw, so the row is not left empty.
    static func hasContent(_ usage: AgentUsage?) -> Bool {
        guard let usage else { return false }
        return AgentContextMeter.fraction(used: usage.contextUsedTokens, window: usage.contextWindowTokens) != nil
            || AgentContextMeter.fiveHour(in: usage.limits) != nil
    }

    private func tone(_ fraction: Double) -> Double {
        AgentContextMeter.isNearlyFull(fraction) ? 0.9 : 0.55
    }

    private var contextPart: (fraction: Double, used: Int, window: Int)? {
        guard let fraction = contextFraction, let used = usage.contextUsedTokens, let window = usage.contextWindowTokens else { return nil }
        return (fraction, used, window)
    }

    private func label(_ part: (fraction: Double, used: Int, window: Int)) -> some View {
        Text(verbatim: AgentContextMeter.label(used: part.used, window: part.window))
            .font(.system(size: 11.5, weight: .medium).monospacedDigit())
            .foregroundStyle(.white.opacity(tone(part.fraction)))
            .fixedSize()
    }

    private var fiveHourText: some View {
        Group {
            if let limit = fiveHour {
                Text("5h \(AgentContextMeter.percent(limit.usedFraction))%")
                    .font(.system(size: 11.5, weight: .medium).monospacedDigit())
                    .foregroundStyle(.white.opacity(tone(limit.usedFraction)))
                    .fixedSize()
            }
        }
    }

    private func bar(_ fraction: Double) -> some View {
        Capsule()
            .fill(.white.opacity(0.14))
            .frame(width: 34, height: 4)
            .overlay(alignment: .leading) {
                Capsule()
                    .fill(.white.opacity(AgentContextMeter.isNearlyFull(fraction) ? 0.95 : 0.55))
                    .frame(width: max(4, 34 * fraction), height: 4)
            }
    }

    /// Takes the room it is given: the bar goes first when the chips leave too little, then the five-hour figure.
    var body: some View {
        Button(action: showsUsage) {
            ViewThatFits(in: .horizontal) {
                content(showsBar: true, showsFiveHour: true)
                content(showsBar: false, showsFiveHour: true)
                content(showsBar: false, showsFiveHour: false)
            }
            .frame(minHeight: 28)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(Text(verbatim: accessibilityText))
        .accessibilityHint(Text("Opens usage and limits"))
    }

    private func content(showsBar: Bool, showsFiveHour: Bool) -> some View {
        HStack(spacing: 8) {
            if let part = contextPart {
                if showsBar { bar(part.fraction) }
                label(part)
            }
            if showsFiveHour { fiveHourText }
        }
    }

    private var accessibilityText: String {
        var parts: [String] = []
        if let fraction = contextFraction {
            parts.append(String(localized: "Context used, \(AgentContextMeter.percent(fraction)) percent"))
        }
        if let limit = fiveHour {
            parts.append(String(localized: "Five-hour limit, \(AgentContextMeter.percent(limit.usedFraction)) percent used"))
        }
        return parts.joined(separator: ". ")
    }
}
