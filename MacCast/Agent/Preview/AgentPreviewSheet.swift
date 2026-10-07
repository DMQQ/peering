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

    private var addressBar: some View {
        HStack(spacing: 8) {
            if browser?.canGoBack == true {
                barButton("chevron.backward", label: "Back") { browser?.goBack() }
            }
            TextField("localhost:3000", text: $typed)
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled()
                .keyboardType(.URL)
                .submitLabel(.go)
                .focused($addressFocused)
                .font(.system(size: 15, design: .monospaced))
                .padding(.horizontal, 14)
                .frame(height: 38)
                .overlay(Capsule().strokeBorder(.white.opacity(0.16)))
                .onSubmit { open() }
            barButton("arrow.clockwise", label: "Reload") { browser?.reload() }
                .disabled(browser?.phase == .idle)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 8)
    }

    private func barButton(_ symbol: String, label: LocalizedStringKey, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.system(size: 14, weight: .semibold))
                .foregroundStyle(ColorPalette.ink)
                .frame(width: 38, height: 38)
                .overlay(Circle().strokeBorder(.white.opacity(0.16)))
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
                start(notice: browser.notice)
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
            ZStack(alignment: .top) {
                PreviewWebView(browser: browser)
                if browser.phase == .loading { ProgressView().padding(.top, 12) }
            }
            if let notice = browser.notice { footnote(notice) }
            footnote(String(localized: "Live reload over WebSocket is not carried here. Reload to see changes."))
        }
    }

    private func footnote(_ text: String) -> some View {
        Text(text)
            .font(.caption)
            .foregroundStyle(.tertiary)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, 16)
            .padding(.vertical, 6)
    }

    private func start(notice: String?) -> some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 14) {
                Text("Open a server running on your Mac")
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(ColorPalette.ink)
                Text("Type a port, or pick one that is answering now. Only localhost and 127.0.0.1 on the Mac can be opened.")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                portChips
                if let notice {
                    Text(notice).font(.footnote).foregroundStyle(ColorPalette.caution)
                }
                Text("Live reload over WebSocket is not carried here. Reload to see changes.")
                    .font(.caption)
                    .foregroundStyle(.tertiary)
            }
            .cardSurface()
            .padding(16)
        }
    }

    private var portChips: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 8) {
                Text(detected.isEmpty && !isProbing ? "Nothing found on the usual ports" : "On the Mac now")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                if isProbing { ProgressView().controlSize(.mini) }
                Spacer()
                Button("Look again") { Task { await detect() } }
                    .font(.caption.weight(.medium))
                    .disabled(isProbing)
            }
            HStack(spacing: 8) {
                ForEach(detected, id: \.self) { port in
                    Button { typed = "localhost:\(port)"; open() } label: {
                        Text(verbatim: ":\(port)")
                            .font(.system(size: 14, weight: .medium, design: .monospaced))
                            .foregroundStyle(ColorPalette.ink)
                            .padding(.horizontal, 14)
                            .frame(height: 34)
                            .overlay(Capsule().strokeBorder(.white.opacity(0.3)))
                    }
                }
            }
        }
    }

    private func failure(_ reason: PreviewFailure, browser: PreviewBrowser) -> some View {
        VStack(spacing: 14) {
            Spacer()
            Image(systemName: "bolt.horizontal.circle")
                .font(.system(size: 34, weight: .light))
                .foregroundStyle(.secondary)
            Text(Self.title(reason))
                .font(.headline)
                .foregroundStyle(ColorPalette.ink)
            Text(Self.explanation(reason))
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
            Button { browser.reload() } label: {
                Text("Try again")
                    .font(.subheadline.weight(.medium))
                    .foregroundStyle(ColorPalette.ink)
                    .padding(.horizontal, 22)
                    .frame(height: 40)
                    .overlay(Capsule().strokeBorder(.white.opacity(0.3)))
            }
            Spacer()
        }
        .padding(.horizontal, 32)
        .frame(maxWidth: .infinity)
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
