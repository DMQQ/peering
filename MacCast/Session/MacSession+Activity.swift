import Foundation
import MacCastKit
import Observation
import RemoteCore
import SwiftUI
import UIKit
import os

extension MacSession {
    /// Capped: a Lock Screen has room for a few lines and the card's own line says how many Macs are open.
    func workItems() -> [SessionActivityAttributes.ContentState.Work] {
        var work: [SessionActivityAttributes.ContentState.Work] = []
        for session in agentSessions {
            let folder = session.directory.split(separator: "/").last.map(String.init)
            switch session.state {
            case .awaitingApproval:
                work.append(.init(name: session.title, symbol: "questionmark.bubble", state: .waiting, detail: folder))
            case .working:
                work.append(.init(
                    name: session.title,
                    symbol: TerminalAgent.all.first { $0.id == session.agentID }?.symbol ?? "sparkles",
                    state: .live,
                    detail: folder
                ))
            case .failed:
                work.append(.init(name: session.title, symbol: "exclamationmark.triangle", state: .failed, detail: folder))
            case .idle, .exited:
                break
            }
        }
        for terminal in terminals where terminal.isRunning {
            if terminal.attention != nil {
                work.append(.init(name: terminal.name, symbol: "lock", state: .waiting))
            } else if terminal.failure != nil {
                work.append(.init(name: terminal.name, symbol: "exclamationmark.triangle", state: .failed))
            } else {
                work.append(.init(name: terminal.name, symbol: "terminal", state: .live))
            }
        }
        return Array(work.sorted { $0.state.isWaiting && !$1.state.isWaiting }.prefix(4))
    }

    /// Called from every terminal and agent event rather than the screens: the card matters when nobody is looking at the app.
    func publishWork() {
        guard model.activeSessionID == id else { return }
        let work = workItems()
        guard work != publishedWork else { return }
        publishedWork = work
        SessionActivity.shared.workChanged(work)
    }
}
