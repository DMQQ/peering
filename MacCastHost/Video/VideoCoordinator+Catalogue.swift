import AVFoundation
import CoreGraphics
import CoreMedia
import Foundation
import RemoteCore
import os

extension VideoCoordinator {
/// Re-reads the source list and offers it to ``onCatalog``.
    func forgetWindowListIfStale() {
        pipeline.forgetWindowListIfStale()
    }

    /// Drops the cached window list and sends the phone a fresh one, for a change this host made.
    func refreshWindowList() {
        pipeline.forgetWindowList()
        refreshCatalog(immediate: true)
    }

    func refreshCatalog(immediate: Bool = false) {
        lock.withLock {
            if let pending = pendingCatalogPush {
                guard immediate, pendingCatalogPushIsWaiting else { return }
                pending.cancel()
            }
            let since = lastCatalogPushAt.map { Date().timeIntervalSince($0) } ?? .infinity
            let wait = immediate ? 0 : max(0, Self.catalogPushInterval - since)
            pendingCatalogPushID &+= 1
            let id = pendingCatalogPushID
            pendingCatalogPushIsWaiting = wait > 0
            pendingCatalogPush = Task { [weak self] in
                if wait > 0 { try? await Task.sleep(for: .seconds(wait)) }
                guard let self else { return }
                let current = self.lock.withLock { () -> Bool in
                    guard self.pendingCatalogPushID == id else { return false }
                    self.lastCatalogPushAt = Date()
                    self.pendingCatalogPush = nil
                    self.pendingCatalogPushIsWaiting = false
                    return true
                }
                guard current else { return }
                await self.pushCatalog()
            }
        }
    }

    static let catalogPushInterval: TimeInterval = 3

    func pushCatalog() async {
        do {
            let catalog = try await pipeline.catalog()

// Offered every time, with no "unchanged, skip it" check here. A host-wide "last catalogue" cannot
// tell which client already has it, so it answers "nobody needs this" for every client that has not
// connected yet: the first client suppressed the push for all the others, and every later client got
// an empty source picker. The suppression belongs where the knowledge is: each ``HostSession``
            onCatalog?(catalog)
// The Space count and preview count are the only way to tell a host that has never seen a desktop
// from one that has: both send the same picker, and the difference is a screenshot that either
// happened or was refused.
            coordinatorLog.notice("""
                capture catalogue · \(catalog.displays.count, privacy: .public) display(s), \
                \(catalog.applications.count, privacy: .public) application(s), \
                \(catalog.windows.count, privacy: .public) window(s), \
                \(catalog.installedApplications.count, privacy: .public) installed application(s), \
                \(catalog.spaceInfo?.displays.count ?? 0, privacy: .public) display(s) with \
                \(catalog.spaceInfo?.totalCount ?? 0, privacy: .public) space(s) \
                and \(catalog.spaceInfo?.previews.count ?? 0, privacy: .public) preview(s)
                """)
        } catch {
            coordinatorLog.notice("""
                could not read the capture catalogue: \(error.localizedDescription, privacy: .public)
                """)
        }
    }
}
