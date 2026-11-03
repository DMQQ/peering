import PeeringKit
import RemoteCore
import SSHCore
import SwiftUI
import UIKit

/// A type of this screen's own, not a protocol over the two records: a Mac session and a shell answer different questions and the list needs only a name, a sentence and a time.
enum RecentConnection: Identifiable {
    case mac(ClientSessionRecord)
    case shell(SSHConnectionRecord)

    var id: UUID {
        switch self {
        case .mac(let session): return session.id
        case .shell(let record): return record.id
        }
    }

    var startedAt: Date {
        switch self {
        case .mac(let session): return session.startedAt
        case .shell(let record): return record.startedAt
        }
    }
}
