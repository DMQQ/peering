import Foundation
import PeeringKit
import SwiftUI

struct HostLogEntry: Identifiable, Sendable, Equatable {
    enum Level: Sendable, Equatable {
        case info
        case warning
        case failure
    }

    let id: UUID
    let at: Date
    let level: Level
    /// What the window shows, resolved in the Mac's current language at display time. Nil for text
    /// that is already a finished sentence (an operating system error, a library message).
    let localizedMessage: LocalizedStringResource?
    /// The English sentence, for the log file, the diagnostics report and the copied log, so support
    /// can read them whatever language the Mac is in.
    let message: String

    init(at: Date = Date(), level: Level = .info, message: LocalizedStringResource) {
        self.id = UUID()
        self.at = at
        self.level = level
        self.localizedMessage = message
        self.message = message.englishText
    }

    init(at: Date = Date(), level: Level = .info, verbatim: String) {
        self.id = UUID()
        self.at = at
        self.level = level
        self.localizedMessage = nil
        self.message = verbatim
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

extension HostLogEntry {
    var text: Text {
        localizedMessage.map { Text($0) } ?? Text(verbatim: message)
    }
}
