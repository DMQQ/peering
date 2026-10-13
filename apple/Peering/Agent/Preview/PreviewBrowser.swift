import Foundation
import Observation
import RemoteCore
import WebKit

/// The web view behind the preview screen, and what the screen needs to know about it.
@MainActor
@Observable
final class PreviewBrowser: NSObject, WKNavigationDelegate {
    enum Phase: Equatable {
        case idle
        case loading
        case loaded
        case failed(PreviewFailure)
    }

    private(set) var phase: Phase = .idle
    private(set) var address = ""
    private(set) var canGoBack = false
    private(set) var notice: String?

    @ObservationIgnored let webView: WKWebView
    @ObservationIgnored private var pageFailure: PreviewFailure?
    @ObservationIgnored private var lastURL: URL?

    init(fetch: @escaping PreviewSchemeHandler.Fetch) {
        let configuration = WKWebViewConfiguration()
        configuration.websiteDataStore = .nonPersistent()
        let box = FailureBox()
        configuration.setURLSchemeHandler(
            PreviewSchemeHandler(fetch: fetch) { box.record($0) },
            forURLScheme: PreviewURLMapping.scheme
        )
        webView = WKWebView(frame: .zero, configuration: configuration)
        super.init()
        box.owner = self
        webView.navigationDelegate = self
        webView.isOpaque = false
        webView.backgroundColor = .clear
        webView.allowsBackForwardNavigationGestures = true
    }

    /// Returns whether the text named a loopback address; anything else is left unloaded.
    @discardableResult
    func load(typed text: String) -> Bool {
        guard let url = PreviewURLMapping.url(fromTyped: text) else {
            notice = String(localized: "Only localhost and 127.0.0.1 can be opened here, with a port.")
            return false
        }
        load(url)
        return true
    }

    func load(_ url: URL) {
        notice = nil
        lastURL = url
        webView.load(URLRequest(url: url, cachePolicy: .reloadIgnoringLocalAndRemoteCacheData))
    }

    func reload() {
        guard let url = webView.url ?? lastURL else { return }
        load(url)
    }

    func goBack() { webView.goBack() }

    fileprivate func pageFailed(_ reason: PreviewFailure) { pageFailure = reason }

    // MARK: WKNavigationDelegate

    func webView(_ webView: WKWebView, decidePolicyFor navigationAction: WKNavigationAction) async -> WKNavigationActionPolicy {
        guard let url = navigationAction.request.url else { return .cancel }
        switch url.scheme?.lowercased() {
        case PreviewURLMapping.scheme, "about":
            return .allow
        case "http", "https":
            // A link to the page's own server written as an absolute URL is brought in; anything else is not this screen's to open.
            if let twin = PreviewURLMapping.previewURL(forLoopback: url) {
                load(twin)
            } else {
                notice = String(localized: "Links outside localhost are not opened here.")
            }
            return .cancel
        default:
            return .cancel
        }
    }

    func webView(_ webView: WKWebView, didStartProvisionalNavigation navigation: WKNavigation!) {
        pageFailure = nil
        phase = .loading
    }

    func webView(_ webView: WKWebView, didCommit navigation: WKNavigation!) { showLocation() }

    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        phase = .loaded
        showLocation()
    }

    func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: any Error) {
        failed(error)
    }

    func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: any Error) {
        failed(error)
    }

    private func failed(_ error: any Error) {
        // A navigation replaced by another one reports itself cancelled; that is not a failure.
        if (error as? URLError)?.code == .cancelled { return }
        phase = .failed(pageFailure ?? .failed)
    }

    private func showLocation() {
        canGoBack = webView.canGoBack
        if let url = webView.url, let shown = PreviewURLMapping.displayAddress(for: url) { address = shown }
    }
}

/// Lets the scheme handler, which is built before the browser exists, report to it afterwards.
@MainActor
private final class FailureBox {
    weak var owner: PreviewBrowser?
    func record(_ reason: PreviewFailure) { owner?.pageFailed(reason) }
}
