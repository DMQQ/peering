import MacCastKit
import RemoteCore
import SwiftUI
import UIKit

/// Both clipboards side by side, and the moves between them.
///
/// Opening it asks the Mac for its clipboard, so the Mac's row is current without a button for it.
/// The iPhone's row cannot show its text for free: reading the pasteboard asks the user, so it names
/// the kind of thing copied and shows the text only once this app has read or written it.
struct ClipboardPanel: View {
    @Binding var chromeFrames: [ChromeRegion: CGRect]
    @Environment(SessionModel.self) private var model
    @State private var phone = PhoneClipboard.current()
    @State private var confirmed: Side?
    @State private var showingHistory = false

    private enum Side { case phone, mac }

    var body: some View {
        VStack(spacing: 8) {
            phoneRow
            macRow
            if !model.clipboardHistory.isEmpty {
                historyRow
            }
        }
        .padding(10)
        .glassSurface(in: RoundedRectangle(cornerRadius: 22, style: .continuous))
        .padding(.horizontal, 10)
        .reportChromeFrame(.panel, into: $chromeFrames)
        .transition(.move(edge: .bottom).combined(with: .opacity))
        .onAppear { model.pullClipboard() }
        .onReceive(NotificationCenter.default.publisher(for: UIPasteboard.changedNotification)) { _ in
            refreshPhone()
        }
        .onReceive(NotificationCenter.default.publisher(for: UIApplication.didBecomeActiveNotification)) { _ in
            refreshPhone()
            model.pullClipboard()
        }
        .onChange(of: model.knownPhoneClipboard?.changeCount) { refreshPhone() }
        .sheet(isPresented: $showingHistory) {
            ClipboardHistoryPanel()
        }
    }

    // MARK: - Rows

    private var phoneRow: some View {
        row(side: .phone, symbol: "iphone", title: "iPhone", detail: phoneDetail, isEmpty: phone.kind == .empty) {
            action("Send", enabled: phone.kind != .empty && isReady) {
                if model.pushClipboard() { confirm(.phone) }
            }
            action("Paste on Mac", prominent: true, enabled: phone.kind != .empty && isReady) {
                model.pushClipboardAndPaste()
                confirm(.phone)
            }
        }
    }

    private var macRow: some View {
        row(side: .mac, symbol: "laptopcomputer", title: "Mac", detail: macDetail, isEmpty: !macHasContent) {
            action("Copy to iPhone", enabled: macHasContent) {
                model.copyHostClipboard()
                confirm(.mac)
            }
        }
    }

    private var historyRow: some View {
        PlanLocked(capability: .clipboardHistory, title: "Clipboard history", placement: .trailing) {
            Button {
                showingHistory = true
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

    private var phoneDetail: String {
        switch phone.kind {
        case .text:
            if let known = model.knownPhoneClipboard, known.changeCount == phone.changeCount {
                return known.text
            }
            return "Text copied"
        case .image: return "Image copied"
        case .empty: return "Nothing copied"
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
            return model.clipboardPulling ? "Checking…" : "Not checked yet"
        }
        switch payload.kind {
        case .text:
            let text = payload.text ?? ""
            return text.isEmpty ? "Nothing to copy" : text
        case .image:
            return payload.carriedImage == nil ? "Nothing to copy" : "Image"
        }
    }

    private func refreshPhone() {
        phone = PhoneClipboard.current()
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
