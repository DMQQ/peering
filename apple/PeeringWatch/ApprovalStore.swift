import Foundation
import Observation
import UserNotifications
import WatchKit
import WatchLink

/// What the watch knows is waiting: the phone's list while it is connected, plus the questions the phone sent as notifications while it was not.
@MainActor
@Observable
final class ApprovalStore {
    enum Failure: Equatable {
        case phoneNotReachable
        case notTaken
    }

    private(set) var approvals: [WatchApproval] = []
    private(set) var phoneReachable = true
    private(set) var sending: Set<String> = []
    private(set) var failure: Failure?

    @ObservationIgnored private let phone = PhoneLink()
    @ObservationIgnored private var fromPhone: [WatchApproval] = []
    @ObservationIgnored private var fromNotificationsList: [WatchApproval] = []
    @ObservationIgnored private var started = false

    func start() {
        guard !started else { return }
        started = true
        if DemoApprovals.isOn {
            fromPhone = DemoApprovals.approvals
            rebuild()
            return
        }
        phone.onSnapshot = { [weak self] snapshot in
            Task { @MainActor in self?.adopt(snapshot) }
        }
        phone.onReachability = { [weak self] reachable in
            Task { @MainActor in self?.phoneReachable = reachable }
        }
        phone.start()
        Task { await refresh() }
    }

    /// Reads the questions still waiting as notifications, which is all the watch has when the phone has not been reachable.
    func refresh() async {
        let delivered = await UNUserNotificationCenter.current().deliveredNotifications()
        let fromNotifications = delivered.compactMap { notification -> WatchApproval? in
            let request = notification.request
            return WatchApproval(
                notificationIdentifier: request.identifier,
                category: request.content.categoryIdentifier,
                title: request.content.title,
                subtitle: request.content.subtitle,
                body: request.content.body,
                userInfo: request.content.userInfo,
                date: notification.date
            )
        }
        merge(notifications: fromNotifications)
    }

    func answer(_ approval: WatchApproval, with choice: WatchApproval.Choice) async -> Bool {
        sending.insert(approval.approvalID)
        failure = nil
        defer { sending.remove(approval.approvalID) }
        guard await phone.send(approval.answer(choice)) else {
            failure = phone.isReachable ? .notTaken : .phoneNotReachable
            return false
        }
        remove(approval)
        return true
    }

    func clearFailure() {
        failure = nil
    }

    private func adopt(_ snapshot: WatchApprovalSnapshot) {
        let arrived = Set(snapshot.approvals.map(\.approvalID)).subtracting(approvals.map(\.approvalID))
        fromPhone = snapshot.approvals
        rebuild()
        if !arrived.isEmpty { WKInterfaceDevice.current().play(.notification) }
    }

    private func merge(notifications: [WatchApproval]) {
        fromNotificationsList = notifications
        rebuild()
    }

    private func rebuild() {
        let known = Set(fromPhone.map(\.approvalID))
        let extra = fromNotificationsList.filter { !known.contains($0.approvalID) }
        approvals = (fromPhone + extra).sorted { $0.postedAt > $1.postedAt }
    }

    private func remove(_ approval: WatchApproval) {
        fromPhone.removeAll { $0.approvalID == approval.approvalID }
        fromNotificationsList.removeAll { $0.approvalID == approval.approvalID }
        rebuild()
        let identifier = WatchApproval.NotificationShape.identifierPrefix + approval.approvalID
        UNUserNotificationCenter.current().removeDeliveredNotifications(withIdentifiers: [identifier])
    }
}
