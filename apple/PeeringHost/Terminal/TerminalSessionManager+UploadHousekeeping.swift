import Foundation
import PeeringKit
import RemoteCore
import os

extension TerminalSessionManager {
    private static let stagingFoldersKey = "pl.dmq.peering.host.uploadFolders"
    private static let maximumRememberedFolders = 50

    /// Remembered because a crash leaves scratch files beside destinations only this process ever saw.
    func rememberStagingFolder(_ folder: URL) {
        var folders = UserDefaults.standard.stringArray(forKey: Self.stagingFoldersKey) ?? []
        guard !folders.contains(folder.path) else { return }
        folders.append(folder.path)
        UserDefaults.standard.set(Array(folders.suffix(Self.maximumRememberedFolders)), forKey: Self.stagingFoldersKey)
    }

    /// At launch no transfer is in progress, so every scratch file in a remembered folder is an orphan.
    static func sweepStagingFilesAtLaunch() {
        let folders = UserDefaults.standard.stringArray(forKey: stagingFoldersKey) ?? []
        UserDefaults.standard.removeObject(forKey: stagingFoldersKey)
        for folder in folders {
            let names = (try? FileManager.default.contentsOfDirectory(atPath: folder)) ?? []
            for name in names where UploadWritePolicy.isStagingFile(named: name) {
                try? FileManager.default.removeItem(atPath: (folder as NSString).appendingPathComponent(name))
            }
        }
    }

    /// A timer that exists only while a transfer does.
    func startIdleSweepIfNeeded() {
        lock.withLock {
            guard idleSweepTimer == nil else { return }
            let timer = DispatchSource.makeTimerSource(queue: Self.writeIO)
            timer.schedule(deadline: .now() + 30, repeating: 30)
            timer.setEventHandler { [weak self] in self?.dropIdleWrites() }
            idleSweepTimer = timer
            timer.resume()
        }
    }

    private func dropIdleWrites() {
        let now = ProcessInfo.processInfo.systemUptime
        let dropped = lock.withLock { () -> [(WriteKey, PendingWrite)] in
            let idle = UploadWritePolicy.idle(writes.mapValues(\.lastActivity), now: now)
            let dropped = idle.compactMap { key in writes.removeValue(forKey: key).map { (key, $0) } }
            if writes.isEmpty {
                idleSweepTimer?.cancel()
                idleSweepTimer = nil
            }
            return dropped
        }
        for (key, pending) in dropped {
            pending.discard()
            terminalLog.notice("dropped an idle upload of \(pending.path, privacy: .private)")
            send(
                .writeFailure(
                    sessionID: key.sessionID,
                    path: pending.path,
                    message: "That transfer stopped sending, so this Mac dropped it."
                ),
                to: pending.ownerClientID
            )
        }
    }
}
