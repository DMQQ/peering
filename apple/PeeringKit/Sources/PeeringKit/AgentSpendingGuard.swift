import Foundation
import RemoteCore

/// Whether a chat has gone past the cap the person set for it, and so whether its waiting messages may go on their own.
public enum AgentSpendingGuard {
    public enum Overrun: Equatable, Sendable {
        case cost(spentUSD: Double, capUSD: Double)
        case context(percent: Int, capPercent: Int)
    }

    /// Cost is checked first: money spent is the harder limit to undo. Nil with no cap or nothing reported to compare.
    public static func overrun(cap: AgentSpendingCap?, usage: AgentUsage?) -> Overrun? {
        guard let cap, let usage else { return nil }
        if let capUSD = cap.costUSD, let spent = usage.costUSD, spent >= capUSD {
            return .cost(spentUSD: spent, capUSD: capUSD)
        }
        if let capPercent = cap.contextPercent,
           let fraction = AgentContextMeter.fraction(used: usage.contextUsedTokens, window: usage.contextWindowTokens) {
            let percent = AgentContextMeter.percent(fraction)
            if percent >= capPercent { return .context(percent: percent, capPercent: capPercent) }
        }
        return nil
    }

    /// Past the cap, every waiting message needs the person: each one sent by hand moves the queue by one.
    public static func holdsQueue(cap: AgentSpendingCap?, usage: AgentUsage?) -> Bool {
        overrun(cap: cap, usage: usage) != nil
    }

    /// A cap typed in the phone's sheet, or nil when the field is empty or not a positive number.
    public static func parsedCost(_ text: String, locale: Locale = .current) -> Double? {
        let trimmed = text.trimmingCharacters(in: .whitespaces).replacingOccurrences(of: "$", with: "")
        guard !trimmed.isEmpty else { return nil }
        let normalised = trimmed.replacingOccurrences(of: locale.decimalSeparator ?? ".", with: ".")
        guard let value = Double(normalised), value > 0, value.isFinite else { return nil }
        return value
    }

    /// 1 to 100, or nil.
    public static func parsedPercent(_ text: String) -> Int? {
        let trimmed = text.trimmingCharacters(in: .whitespaces).replacingOccurrences(of: "%", with: "")
        guard let value = Int(trimmed), (1 ... 100).contains(value) else { return nil }
        return value
    }
}
