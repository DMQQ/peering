import MacCastKit
import RemoteCore
import SwiftUI
import UIKit

/// Reading the iPhone pasteboard asks the user, so its text is shown only once this app has read or written it.
struct ClipboardPanel: View {
    @Binding var chromeFrames: [ChromeRegion: CGRect]
    @Environment(SessionModel.self) private var model
    @State private var phone = PhoneClipboard.current()
    @State private var confirmed: Side?
    @State private var refusal: String?
    @State private var showingHistory = false

    private enum Side { case phone, mac }

    var body: some View {
        Group {
            if showingHistory {
                ClipboardHistoryPanel {
                    withAnimation(Motion.settle) { showingHistory = false }
                }
                .transition(.blurReplace(.downUp))
            } else {
                VStack(spacing: 8) {
                    phoneRow
                    macRow
                    if !model.clipboardHistory.isEmpty {
                        historyRow
                    }
                }
                .transition(.blurReplace(.downUp))
            }
        }
        .padding(10)
        .onAppear { model.pullClipboard() }
        .onReceive(NotificationCenter.default.publisher(for: UIPasteboard.changedNotification)) { _ in
            refreshPhone()
        }
        .onReceive(NotificationCenter.default.publisher(for: UIApplication.didBecomeActiveNotification)) { _ in
            refreshPhone()
            model.pullClipboard()
        }
        .onChange(of: model.knownPhoneClipboard?.changeCount) { refreshPhone() }
    }

    // MARK: - Rows

    private var phoneRow: some View {
        row(side: .phone, symbol: "iphone", title: "iPhone", detail: refusal ?? phoneDetail, isEmpty: phone.kind == .empty) {
            if phone.kind == .text, !phoneTextIsKnown {
                // Reading asks the user, so only on a tap. "Allow" in the app's settings stops it.
                action(String(localized: "Show"), enabled: true) {
                    let board = UIPasteboard.general
                    if let text = board.string {
                        model.knownPhoneClipboard = (board.changeCount, text)
                    }
                }
            }
            action("Send", enabled: phone.kind != .empty && isReady) {
                handle(model.pushClipboard())
            }
            action(String(localized: "Paste on Mac"), prominent: true, enabled: phone.kind != .empty && isReady) {
                handle(model.pushClipboardAndPaste())
            }
        }
    }

    private var macRow: some View {
        row(side: .mac, symbol: "laptopcomputer", title: "Mac", detail: macDetail, isEmpty: !macHasContent) {
            action(String(localized: "Copy to iPhone"), enabled: macHasContent) {
                model.copyHostClipboard()
                confirm(.mac)
            }
        }
    }

    private var historyRow: some View {
        PlanLocked(capability: .clipboardHistory, title: String(localized: "Clipboard history"), placement: .trailing) {
            Button {
                withAnimation(Motion.settle) { showingHistory = true }
            } label: {
                HStack(spacing: 11) {
                    icon("clock.arrow.circlepath")
                    Text("History")
                        .font(.subheadline.weight(.medium))
                    Text("\(model.clipboardHistory.count)")
                        .font(.caption.monospacedDigit())
                        .foregroundStyle(.secondary)
                    Spacer(minLength: 10)
                    Image(systemName: "chevron.right")
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundStyle(.tertiary)
                }
                .padding(10)
                .contentShape(Rectangle())
                .rowSurface()
            }
            .buttonStyle(RailButtonStyle(scale: 0.97))
        }
    }

    private func row<Actions: View>(
        side: Side,
        symbol: String,
        title: String,
        detail: String,
        isEmpty: Bool,
        @ViewBuilder actions: () -> Actions
    ) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .top, spacing: 11) {
                icon(symbol)
                VStack(alignment: .leading, spacing: 2) {
                    HStack(spacing: 6) {
                        Text(title)
                            .font(.subheadline.weight(.semibold))
                        if confirmed == side {
                            Image(systemName: "checkmark")
                                .font(.system(size: 11, weight: .bold))
                                .foregroundStyle(ColorPalette.accent)
                                .transition(.opacity)
                        }
                    }
                    Text(detail)
                        .font(.caption)
                        .foregroundStyle(isEmpty ? .tertiary : .secondary)
                        .lineLimit(2)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
            }
            HStack(spacing: 8) {
                Spacer(minLength: 0)
                actions()
            }
        }
        .padding(10)
        .rowSurface()
    }

    private func icon(_ symbol: String) -> some View {
        Image(systemName: symbol)
            .font(.system(size: 13, weight: .semibold))
            .foregroundStyle(ColorPalette.ink)
            .frame(width: 28, height: 28)
            .background(ColorPalette.ink.opacity(0.14), in: RoundedRectangle(cornerRadius: 8, style: .continuous))
    }

    private func action(
        _ title: String,
        prominent: Bool = false,
        enabled: Bool,
        perform: @escaping () -> Void
    ) -> some View {
        Button(action: perform) {
            Text(title)
                .font(.subheadline.weight(prominent ? .semibold : .medium))
                .foregroundStyle(prominent ? ColorPalette.onInk : ColorPalette.ink)
                .padding(.horizontal, 12)
                .padding(.vertical, 7)
                .background(prominent ? ColorPalette.ink : ColorPalette.ink.opacity(0.12), in: Capsule())
                .contentShape(Capsule())
        }
        .buttonStyle(RailButtonStyle(scale: 0.94, haptic: true))
        .disabled(!enabled)
        .opacity(enabled ? 1 : 0.4)
    }

    // MARK: - State

    private var isReady: Bool { model.phase == .ready }

    private var phoneTextIsKnown: Bool {
        model.knownPhoneClipboard?.changeCount == phone.changeCount
    }

    private var phoneDetail: String {
        switch phone.kind {
        case .text:
            if let known = model.knownPhoneClipboard, known.changeCount == phone.changeCount {
                return known.text
            }
            return String(localized: "Text from another app. Allow pasting in Settings > Peering to skip the prompt.")
        case .image: return String(localized: "Image copied")
        case .empty: return String(localized: "Nothing copied")
        }
    }

    private var macHasContent: Bool {
        guard let payload = model.hostClipboard else { return false }
        switch payload.kind {
        case .text: return !(payload.text ?? "").isEmpty
        case .image: return payload.carriedImage != nil
        }
    }

    private var macDetail: String {
        guard let payload = model.hostClipboard else {
            return model.clipboardPulling ? String(localized: "Checking…") : String(localized: "Not checked yet")
        }
        switch payload.kind {
        case .text:
            let text = payload.text ?? ""
            return text.isEmpty ? String(localized: "Nothing to copy") : text
        case .image:
            return payload.carriedImage == nil ? String(localized: "Nothing to copy") : String(localized: "Image")
        }
    }

    private func refreshPhone() {
        let current = PhoneClipboard.current()
        if current.changeCount != phone.changeCount { refusal = nil }
        phone = current
    }

    private func handle(_ result: ClipboardPushResult) {
        switch result {
        case .sent:
            refusal = nil
            confirm(.phone)
        case .imageTooLarge(let bytes):
            let size = ByteCountFormatter.string(fromByteCount: Int64(bytes), countStyle: .file)
            let limit = ByteCountFormatter.string(fromByteCount: Int64(ClipboardLimits.maxImageBytes), countStyle: .file)
            withAnimation(Motion.tap) { refusal = String(localized: "Image too large to send (\(size), limit \(limit))") }
        case .failed:
            break
        }
    }

    private func confirm(_ side: Side) {
        withAnimation(Motion.tap) { confirmed = side }
        Task {
            try? await Task.sleep(for: .seconds(1.5))
            withAnimation(Motion.tap) { if confirmed == side { confirmed = nil } }
        }
    }
}

/// What kind of thing is on the iPhone's pasteboard, read without triggering the paste prompt.
private struct PhoneClipboard: Equatable {
    enum Kind { case empty, text, image }

    let kind: Kind
    let changeCount: Int

    static func current() -> PhoneClipboard {
        let board = UIPasteboard.general
        let kind: Kind = board.hasImages ? .image : (board.hasStrings || board.hasURLs ? .text : .empty)
        return PhoneClipboard(kind: kind, changeCount: board.changeCount)
    }
}
