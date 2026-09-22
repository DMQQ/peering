import Foundation
import MacCastKit
import RemoteCore
import UIKit

extension SessionModel {

    // MARK: - Clipboard

    /// Requests the Mac's clipboard. The result arrives as ``hostClipboard`` once the host responds.
    ///
    /// One request for both kinds, because which kind it is is a fact about the Mac's pasteboard
    /// and only the Mac can look at it.
    func pullClipboard() {
        guard phase == .ready else { return }
        clipboardPulling = true
        session?.send(.requestClipboard)
    }

    /// Pushes what is on the iPhone's clipboard to the Mac's pasteboard.
    ///
    /// **Whatever is on it.** A picture is sent as a picture and a line of text as text, and the
    /// picture is preferred when the pasteboard is holding both, which is what copying an image
    /// out of a web page leaves there.
    ///
    /// **A picture is not sent to a Mac that has not said it can take one**, and the pasteboard's
    /// text goes instead when there is any. A Mac built before the command existed has never heard
    /// of it, and an unknown command is a decode failure in the middle of a session rather than a
    /// copy that quietly does nothing — so the picture would cost the session. See
    /// ``ClipboardImages``.
    ///
    /// **Silent when the picture is too large to carry**, rather than sending a truncated one: the
    /// Mac would refuse to buffer it and nothing would arrive either way. See
    /// ``ClipboardLimits/maxImageBytes``. There is no message for the user here yet, which is the
    /// one rough edge this leaves: a screenshot over the limit pushes nothing and says nothing.
    func pushClipboard() {
        guard phase == .ready else { return }
        let board = UIPasteboard.general

        if activeSession?.hostSupportsClipboardImages == true, let png = clipboardImage(from: board) {
            session?.pushClipboardImage(png)
            return
        }
        guard let text = board.string else { return }
        session?.send(.pushClipboard(text: text))
    }

    /// The iPhone's pasteboard as PNG, or `nil` when it is not holding a picture.
    ///
    /// **The bytes the pasteboard already has, when it has them.** A screenshot copied on the
    /// phone is on it as PNG, and `UIPasteboard.image` would decode it and `pngData()` would encode
    /// it again: work proportional to the picture's size, on the main thread, to arrive back at the
    /// bytes that were there to begin with. `NSItemProvider`'s types are the fallback for a
    /// pasteboard that holds a photograph as data and no image.
    private func clipboardImage(from board: UIPasteboard) -> Data? {
        if let png = board.data(forPasteboardType: "public.png") { return png }
        return board.image?.pngData()
    }

    /// Copies the most recently received host clipboard to the iPhone's pasteboard.
    ///
    /// **The size is checked again here**, which is not redundant with the Mac's own check. This
    /// side's limit is a backstop against a Mac that sends more than it promised, and it is the
    /// same figure rather than a smaller one so that it can never engage on a payload the Mac
    /// considered legal. See ``MacCastKit``'s `imagePreviewByteLimit`, whose comment this is.
    func copyHostClipboard() {
        guard let payload = hostClipboard else { return }
        switch payload.kind {
        case .text:
            guard let text = payload.text else { return }
            UIPasteboard.general.string = text
        case .image:
            guard let png = payload.carriedImage, let image = UIImage(data: png) else { return }
            UIPasteboard.general.image = image
        }
    }

    // MARK: - Clipboard history

    struct ClipboardEntry: Codable, Equatable, Identifiable {
        let id: UUID
        let text: String
        let at: Date
    }

    static let clipboardHistoryKey = "Peering.clipboardHistory"
    static let clipboardHistoryLimit = 12

    static func loadClipboardHistory() -> [ClipboardEntry] {
        guard let data = UserDefaults.standard.data(forKey: clipboardHistoryKey) else { return [] }
        return (try? JSONDecoder().decode([ClipboardEntry].self, from: data)) ?? []
    }

    func rememberClipboard(_ text: String) {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        var history = clipboardHistory.filter { $0.text != text }
        history.insert(ClipboardEntry(id: UUID(), text: text, at: Date()), at: 0)
        if history.count > Self.clipboardHistoryLimit {
            history.removeLast(history.count - Self.clipboardHistoryLimit)
        }
        clipboardHistory = history
        persistClipboardHistory()
    }

    func removeClipboardEntry(_ id: UUID) {
        clipboardHistory.removeAll { $0.id == id }
        persistClipboardHistory()
    }

    func clearClipboardHistory() {
        clipboardHistory = []
        persistClipboardHistory()
    }

    /// Puts a history entry on the iPhone's pasteboard, which is what tapping one does.
    func copyToPhone(_ entry: ClipboardEntry) {
        UIPasteboard.general.string = entry.text
        clipboardHistoryCount += 1
    }

    /// Sends a history entry to the Mac's clipboard.
    func pushToMac(_ entry: ClipboardEntry) {
        guard phase == .ready else { return }
        session?.send(.pushClipboard(text: entry.text))
    }

    private func persistClipboardHistory() {
        clipboardHistoryCount += 1
        guard let data = try? JSONEncoder().encode(clipboardHistory) else { return }
        UserDefaults.standard.set(data, forKey: Self.clipboardHistoryKey)
    }
}
