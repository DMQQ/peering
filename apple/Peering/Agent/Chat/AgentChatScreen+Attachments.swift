import PeeringKit
import PhotosUI
import RemoteCore
import SwiftUI

extension AgentChatScreen {
    var attachAvailable: Bool {
        model.browserID != nil && model.hostSupportsFileBrowser
    }

    /// Re-encoded as JPEG: a library photo is usually HEIC, which the agents cannot read.
    func attachPhoto(_ item: PhotosPickerItem, session: RemoteAgentSession) async {
        guard let data = try? await item.loadTransferable(type: Data.self),
              let image = UIImage(data: data),
              let jpeg = image.jpegData(compressionQuality: 0.9)
        else { return }
        let stamp = Date.now.formatted(.verbatim("\(year: .defaultDigits)\(month: .twoDigits)\(day: .twoDigits)-\(hour: .twoDigits(clock: .twentyFourHour, hourCycle: .zeroBased))\(minute: .twoDigits)\(second: .twoDigits)", locale: .init(identifier: "en_US_POSIX"), timeZone: .current, calendar: .current))
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        let url = folder.appendingPathComponent("Photo-\(stamp).jpg")
        do {
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            try jpeg.write(to: url)
        } catch { return }
        beginAttachment(url, session: session)
    }

    func beginAttachment(_ url: URL, session: RemoteAgentSession) {
        guard let id = model.browserID else { return }
        let name = url.lastPathComponent
        let folder = session.directory
        attaching = Attachment(name: name, path: AgentDraft.attachmentPath(folder: folder, name: name), thumbnail: Attachment.thumbnail(of: url))
        model.uploadFile(url, toFolder: folder, sessionID: id)
    }
}
