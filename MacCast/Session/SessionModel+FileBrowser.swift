import Foundation
import MacCastKit
import Observation
import RemoteCore
import SwiftUI
import UIKit
import WidgetKit
import os

extension SessionModel {
    // MARK: - The active Mac's file browser

    var hostSupportsFileBrowser: Bool { activeSession?.hostSupportsFileBrowser ?? false }

    var browserID: UUID? { activeSession?.browserID }

    func openFileScope() { activeSession?.openFileScope() }

    var browserPath: String? {
        guard let session = activeSession else { return nil }
        return session.browsingPath(for: session.browserID)
    }

    func setBrowserPath(_ path: String?) {
        guard let session = activeSession else { return }
        session.setBrowsingPath(path, for: session.browserID)
        if let path, let mac = session.hostName { FolderMemory().remember(path, for: mac) }
    }

    var rememberedFilesFolder: String? {
        activeSession?.hostName.flatMap { FolderMemory().folder(for: $0) }
    }

    func forgetFilesFolder() {
        if let mac = activeSession?.hostName { FolderMemory().forget(for: mac) }
    }

    func browsingPath(for id: UUID) -> String? { activeSession?.browsingPath(for: id) }

    func setBrowsingPath(_ path: String?, for id: UUID) {
        activeSession?.setBrowsingPath(path, for: id)
    }

    func listDirectory(_ path: String?, sessionID id: UUID) {
        activeSession?.listDirectory(path, sessionID: id)
    }

    func previewFile(_ path: String, sessionID id: UUID) {
        Analytics.featureUsed(.filePreviewed)
        activeSession?.previewFile(path, sessionID: id)
    }

    func closePreview() { activeSession?.closePreview() }

    func saveFile(_ text: String, sessionID id: UUID) {
        Analytics.featureUsed(.fileSaved)
        activeSession?.saveFile(text, sessionID: id)
    }

    /// The chat screen's attachments go into the folder the agent works in, not whatever a browser is looking at.
    func uploadFile(_ url: URL, toFolder folder: String, sessionID id: UUID) {
        Analytics.featureUsed(.fileUpload)
        activeSession?.uploadFile(url, toFolder: folder, sessionID: id)
    }

    func uploadFile(_ url: URL, sessionID id: UUID) {
        activeSession?.uploadFile(url, sessionID: id)
    }

    func uploadItems(_ urls: [URL], sessionID id: UUID) {
        Analytics.featureUsed(.folderUpload)
        activeSession?.uploadItems(urls, sessionID: id)
    }

    func folderProgress(sessionID id: UUID) -> String? {
        activeSession?.folderProgress(sessionID: id)
    }

    func createEntry(_ name: String, kind: RemoteEntryKind, in folder: String, sessionID id: UUID) {
        Analytics.featureUsed(.fileCreated)
        activeSession?.createEntry(name, kind: kind, in: folder, sessionID: id)
    }

    func renameEntry(_ entry: RemoteDirectoryEntry, to name: String, in folder: String, sessionID id: UUID) {
        Analytics.featureUsed(.fileRenamed)
        activeSession?.renameEntry(entry, to: name, in: folder, sessionID: id)
    }

    func deleteEntry(_ entry: RemoteDirectoryEntry, in folder: String, sessionID id: UUID) {
        Analytics.featureUsed(.fileDeleted)
        activeSession?.deleteEntry(entry, in: folder, sessionID: id)
    }

    func directory(_ path: String?, sessionID id: UUID) -> RemoteDirectory? {
        activeSession?.directory(path, sessionID: id)
    }

    func isLoadingDirectory(_ path: String?, sessionID id: UUID) -> Bool {
        activeSession?.isLoadingDirectory(path, sessionID: id) ?? false
    }

    func browseFailure(_ path: String?, sessionID id: UUID) -> String? {
        activeSession?.browseFailure(path, sessionID: id)
    }

    func isChangingFile(sessionID id: UUID) -> Bool {
        activeSession?.isChangingFile(sessionID: id) ?? false
    }

    func changeFailure(sessionID id: UUID) -> String? { activeSession?.changeFailure(sessionID: id) }

    func isWritingFile(sessionID id: UUID) -> Bool {
        activeSession?.isWritingFile(sessionID: id) ?? false
    }

    func saveFailure(sessionID id: UUID) -> String? { activeSession?.saveFailure(sessionID: id) }

    func uploadFailure(sessionID id: UUID) -> String? { activeSession?.uploadFailure(sessionID: id) }
}
