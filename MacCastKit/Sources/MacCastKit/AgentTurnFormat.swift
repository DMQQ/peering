import Foundation

public enum AgentTurnFormat {
    public static func duration(_ seconds: TimeInterval) -> String {
        seconds < 60
            ? String(format: "%.1fs", seconds)
            : "\(Int(seconds) / 60)m \(Int(seconds) % 60)s"
    }
}
