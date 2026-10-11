import Foundation
import MacCastKit

extension SessionModel {
    func noteOpenedChat(_ id: UUID) {
        guard let hostID = activeSession?.hostID, let title = agentCards.first(where: { $0.id == id })?.title else { return }
        LastActivity(kind: .chat, id: id, hostID: hostID, title: title, openedAt: .now).save()
    }

    func noteOpenedTerminal(_ id: UUID) {
        guard let hostID = activeSession?.hostID, let name = terminalCards.first(where: { $0.id == id })?.name else { return }
        LastActivity(kind: .terminal, id: id, hostID: hostID, title: name, openedAt: .now).save()
    }

    /// What the home screen offers: recent, on a Mac that is still paired.
    var activityToResume: LastActivity? {
        guard let last = LastActivity.load(), last.isFresh(at: .now), pairedHostIDs.contains(last.hostID) else { return nil }
        return last
    }

    func resume(_ activity: LastActivity) {
        openFromNotification(hostID: activity.hostID, sourceID: nil)
        InAppBanner.shared.openRequest = activity.kind == .chat ? .chat(activity.id) : .terminal(activity.id)
    }
}
