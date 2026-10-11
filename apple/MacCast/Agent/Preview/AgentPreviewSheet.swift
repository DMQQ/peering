import RemoteCore
import SwiftUI

/// A web page served by the Mac's own loopback, shown on the phone through the connection the session already has.
struct AgentPreviewSheet: View {
    @Environment(SessionModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    @State private var browser: PreviewBrowser?
    @State private var typed = ""
    @State private var detected: [UInt16] = []
    @State private var isProbing = false
    @FocusState private var addressFocused: Bool

    var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
                addressBar
                content
            }
            .background(ColorPalette.backdrop)
            .navigationTitle("Web preview")
            .navigationBarTitleDisplayMode(.inline)
            .toolbarBackground(ColorPalette.backdrop, for: .navigationBar)
            .toolbarBackground(.visible, for: .navigationBar)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) { Button("Done") { dismiss() } }
            }
        }
        .preferredColorScheme(.dark)
        .presentationDragIndicator(.visible)
        .task {
            if browser == nil { browser = PreviewBrowser(fetch: fetch) }
            await detect()
        }
        .onChange(of: browser?.address) { _, address in
            if let address, !addressFocused { typed = address }
        }
    }

    private var fetch: PreviewSchemeHandler.Fetch {
        { [weak model] port, method, target, headers, body in
            guard let wire = model?.activeSession?.wire else {
                return AsyncStream { continuation in
                    continuation.yield(.failure(id: 0, reason: .disconnected))
                    continuation.finish()
                }
            }
            return wire.fetchPreview(port: port, method: method, target: target, headers: headers, body: body)
        }
    }

    private func detect() async {
        guard !isProbing else { return }
        isProbing = true
        detected = await PreviewPortProbe.listening(using: fetch)
        isProbing = false
    }

    // MARK: Address

    /// One capsule: back and reload sit inside it instead of beside it as three separate controls.
    private var addressBar: some View {
        HStack(spacing: 4) {
            if browser?.canGoBack == true {
                fieldButton("chevron.backward", label: "Back") { browser?.goBack() }
            }
            TextField("localhost:3000", text: $typed)
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled()
                .keyboardType(.URL)
                .submitLabel(.go)
                .focused($addressFocused)
                .font(.system(size: 15, design: .monospaced))
                .padding(.leading, browser?.canGoBack == true ? 2 : 12)
                .onSubmit { open() }
            fieldButton("arrow.clockwise", label: "Reload") { browser?.reload() }
                .disabled(browser?.phase == .idle)
        }
        .padding(.horizontal, 4)
        .frame(height: 42)
        .overlay(Capsule().strokeBorder(.white.opacity(0.16)))
        .padding(.horizontal, 14)
        .padding(.vertical, 8)
    }

    private func fieldButton(_ symbol: String, label: LocalizedStringKey, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.system(size: 14, weight: .semibold))
                .foregroundStyle(ColorPalette.ink)
                .frame(width: 36, height: 36)
                .contentShape(Circle())
        }
        .accessibilityLabel(Text(label))
    }

    private func open() {
        addressFocused = false
        browser?.load(typed: typed)
    }

    // MARK: Content

    @ViewBuilder private var content: some View {
        if let browser {
            switch browser.phase {
            case .idle:
                AgentPreviewStart(
                    detected: detected,
                    isProbing: isProbing,
                    notice: browser.notice,
                    open: { typed = "localhost:\($0)"; open() },
                    lookAgain: { Task { await detect() } }
                )
            case .failed(let reason):
                failure(reason, browser: browser)
            case .loading, .loaded:
                page(browser)
            }
        } else {
            Spacer()
        }
    }

    private func page(_ browser: PreviewBrowser) -> some View {
        VStack(spacing: 0) {
            // A line under the bar says a page is on its way; a spinner floating over the page hid its top.
            ProgressView()
                .progressViewStyle(.linear)
                .tint(.white.opacity(0.6))
                .opacity(browser.phase == .loading ? 1 : 0)
                .animation(Motion.settle, value: browser.phase == .loading)
            PreviewWebView(browser: browser)
            if let notice = browser.notice {
                Text(verbatim: notice)
                    .font(.caption)
                    .foregroundStyle(.tertiary)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal, 16)
                    .padding(.vertical, 6)
            }
        }
    }

    private func failure(_ reason: PreviewFailure, browser: PreviewBrowser) -> some View {
        VStack {
            Spacer()
            PreviewEmptyState(
                symbol: "bolt.horizontal",
                title: Self.title(reason),
                detail: Self.explanation(reason)
            ) {
                Button { browser.reload() } label: {
                    Text("Try again")
                        .font(.subheadline.weight(.semibold))
                        .foregroundStyle(ColorPalette.onInk)
                        .padding(.horizontal, 26)
                        .frame(height: 42)
                        .background(ColorPalette.ink, in: Capsule())
                }
                .padding(.top, 6)
            }
            Spacer()
            Spacer()
        }
        .padding(.horizontal, 20)
    }

    private static func title(_ reason: PreviewFailure) -> String {
        switch reason {
        case .notListening: String(localized: "Nothing is listening there")
        case .disconnected: String(localized: "Not connected to the Mac")
        case .timedOut: String(localized: "The server did not answer")
        default: String(localized: "The page could not be opened")
        }
    }

    private static func explanation(_ reason: PreviewFailure) -> String {
        switch reason {
        case .notListening: String(localized: "Ask the agent to start the server, or check the port, then try again.")
        case .disconnected: String(localized: "Reconnect to the Mac and try again.")
        case .timedOut: String(localized: "It accepted the connection but sent nothing back.")
        case .tooLarge: String(localized: "That request was too large to send through the preview.")
        case .notAllowed, .invalidRequest: String(localized: "The preview can only open plain pages on localhost.")
        case .busy: String(localized: "Too many requests are waiting. Try again in a moment.")
        case .failed: String(localized: "The Mac could not fetch it.")
        }
    }
}
