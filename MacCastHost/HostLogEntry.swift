import Foundation

struct HostLogEntry: Identifiable, Sendable, Equatable {
    enum Level: Sendable, Equatable {
        case info
        case warning
        case failure
    }

    let id: UUID
    let at: Date
    let level: Level
    let message: String

    init(at: Date = Date(), level: Level = .info, message: String) {
        self.id = UUID()
        self.at = at
        self.level = level
        self.message = message
    }

    var time: String {
        Self.formatter.string(from: at)
    }

    var levelName: String {
        switch level {
        case .info: return String(localized: "Event")
        case .warning: return String(localized: "Notice")
        case .failure: return String(localized: "Failed")
        }
    }

    var levelSymbol: String {
        switch level {
        case .info: return "circle.fill"
        case .warning: return "exclamationmark.circle.fill"
        case .failure: return "xmark.octagon.fill"
        }
    }

    private static let formatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateFormat = "HH:mm:ss"
        return formatter
    }()
}

extension Array where Element == HostLogEntry {
    var plainText: String {
        map { entry in
            let level = switch entry.level {
            case .info: "     "
            case .warning: "WARN "
            case .failure: "FAIL "
            }
            return "\(entry.time)  \(level)\(entry.message)"
        }
        .joined(separator: "\n")
    }
}
