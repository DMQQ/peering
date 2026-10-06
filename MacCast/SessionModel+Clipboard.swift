import Foundation
import MacCastKit
import RemoteCore
import UIKit

enum ClipboardPushResult: Equatable {
    case sent
    case imageTooLarge(bytes: Int)
    case failed
}

extension SessionModel {

    // MARK: - Clipboard

    func pullClipboard() {
        guard phase == .ready else { return }
        clipboardPulling = true
        session?.send(.requestClipboard)
    }

    /// A picture is not sent to a Mac that has not said it can take one: an unknown command is a decode failure mid-session, so the picture would cost the session. Text goes instead.
    /// A picture over `maxImageBytes` is refused, not truncated, and the caller is told its size; the text is not sent in its place.
    @discardableResult
    func pushClipboard() -> ClipboardPushResult {
        guard phase == .ready else { return .failed }
        let board = UIPasteboard.general

        if activeSession?.hostSupportsClipboardImages == true, let png = clipboardImage(from: board) {
            guard png.count <= ClipboardLimits.maxImageBytes else { return .imageTooLarge(bytes: png.count) }
            guard session?.pushClipboardImage(png) == true else { return .failed }
            hostClipboard = .image(png)
            return .sent
        }
        guard let text = board.string else { return .failed }
        knownPhoneClipboard = (board.changeCount, text)
        session?.send(.pushClipboard(text: text))
        hostClipboard = .text(text)
        return .sent
    }

    /// The Mac writes its pasteboard before the next command, so the keystroke cannot paste the old contents.
    @discardableResult
    func pushClipboardAndPaste() -> ClipboardPushResult {
        let result = pushClipboard()
        guard result == .sent else { return result }
        send(.keyDown(keyCode: 9, modifiers: [.command]))
        send(.keyUp(keyCode: 9, modifiers: [.command]))
        return result
    }

    /// Uses the bytes the pasteboard already has: `UIPasteboard.image` plus `pngData()` would decode and re-encode on the main thread. `NSItemProvider` types are the fallback for a photograph held as data.
    private func clipboardImage(from board: UIPasteboard) -> Data? {
        if let png = board.data(forPasteboardType: "public.png") { return png }
        return board.image?.pngData()
    }

    /// The size is checked again here as a backstop against a Mac that sends more than it promised; it is the same figure as the Mac's so it never rejects a payload the Mac considered legal.
    func copyHostClipboard() {
        guard let payload = hostClipboard else { return }
        switch payload.kind {
        case .text:
            guard let text = payload.text, !text.isEmpty else { return }
            UIPasteboard.general.string = text
            knownPhoneClipboard = (UIPasteboard.general.changeCount, text)
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

    func copyToPhone(_ entry: ClipboardEntry) {
        UIPasteboard.general.string = entry.text
        knownPhoneClipboard = (UIPasteboard.general.changeCount, entry.text)
        clipboardHistoryCount += 1
    }

    func pushToMac(_ entry: ClipboardEntry) {
        guard phase == .ready else { return }
        session?.send(.pushClipboard(text: entry.text))
        hostClipboard = .text(entry.text)
    }

    private func persistClipboardHistory() {
        clipboardHistoryCount += 1
        guard let data = try? JSONEncoder().encode(clipboardHistory) else { return }
        UserDefaults.standard.set(data, forKey: Self.clipboardHistoryKey)
    }
}
