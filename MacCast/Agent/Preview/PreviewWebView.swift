import SwiftUI
import WebKit

struct PreviewWebView: UIViewRepresentable {
    let browser: PreviewBrowser

    func makeUIView(context: Context) -> WKWebView { browser.webView }

    func updateUIView(_ view: WKWebView, context: Context) {}
}
