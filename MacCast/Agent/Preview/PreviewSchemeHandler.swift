import Foundation
import RemoteCore
import WebKit

/// Answers the web view's requests for `peering-preview://` by asking the Mac to fetch them from its loopback.
@MainActor
final class PreviewSchemeHandler: NSObject, WKURLSchemeHandler {
    typealias Fetch = @MainActor (UInt16, String, String, [PreviewHeader], Data?) -> AsyncStream<PreviewProxyEvent>

    private let fetch: Fetch
    /// Told when the page itself (not one of its files) could not be had, so the screen can say why.
    private let onPageFailure: @MainActor (PreviewFailure) -> Void
    private var running: [ObjectIdentifier: Task<Void, Never>] = [:]
    private let maxRedirects = 5

    init(fetch: @escaping Fetch, onPageFailure: @escaping @MainActor (PreviewFailure) -> Void) {
        self.fetch = fetch
        self.onPageFailure = onPageFailure
    }

    func webView(_ webView: WKWebView, start urlSchemeTask: any WKURLSchemeTask) {
        let key = ObjectIdentifier(urlSchemeTask)
        running[key] = Task { [weak self] in
            guard let self else { return }
            await self.serve(urlSchemeTask, key: key)
            self.running[key] = nil
        }
    }

    func webView(_ webView: WKWebView, stop urlSchemeTask: any WKURLSchemeTask) {
        // After this returns WebKit raises if the task is touched again, so the loop checks `running` before every call.
        running.removeValue(forKey: ObjectIdentifier(urlSchemeTask))?.cancel()
    }

    // MARK: Serving

    private func serve(_ task: any WKURLSchemeTask, key: ObjectIdentifier) async {
        let original = task.request
        guard var url = original.url else { return fail(task, key, URLError(.badURL)) }
        var method = original.httpMethod ?? "GET"
        var body = Self.body(of: original)
        let headers = (original.allHTTPHeaderFields ?? [:]).map { PreviewHeader(name: $0.key, value: $0.value) }
        let isPage = original.mainDocumentURL == original.url

        for _ in 0...maxRedirects {
            guard let (port, target) = PreviewURLMapping.parse(url) else {
                return fail(task, key, URLError(.badURL), page: isPage ? .notAllowed : nil)
            }
            let events = fetch(port, method, target, headers, body)
            switch await relay(events, to: task, key: key, url: url, isPage: isPage) {
            case .finished:
                return
            case .redirect(let next, let status):
                // Browsers turn a POST that was redirected into a GET, except for 307 and 308.
                if ![307, 308].contains(status), method != "GET", method != "HEAD" { method = "GET"; body = nil }
                if isPage { return respondWithRedirect(to: next, task: task, key: key, url: url) }
                url = next
            }
        }
        fail(task, key, URLError(.httpTooManyRedirects))
    }

    private enum Outcome {
        case finished
        case redirect(URL, status: Int)
    }

    /// Passes one answer on to the web view. Text is held back whole, because the loopback URLs inside it are rewritten first.
    private func relay(
        _ events: AsyncStream<PreviewProxyEvent>,
        to task: any WKURLSchemeTask,
        key: ObjectIdentifier,
        url: URL,
        isPage: Bool
    ) async -> Outcome {
        var status = 0
        var headers: [PreviewHeader] = []
        var held: Data?
        var sent = false

        for await event in events {
            guard running[key] != nil else { return .finished }
            switch event {
            case .head(_, let code, let received):
                status = code
                headers = received
                let location = received.first { $0.name.lowercased() == "location" }?.value
                switch PreviewURLMapping.redirect(status: code, location: location, from: url) {
                case .follow(let next): return .redirect(next, status: code)
                case .refuse:
                    fail(task, key, URLError(.redirectToNonExistentLocation), page: isPage ? .notAllowed : nil)
                    return .finished
                case .notARedirect: break
                }
                let type = received.first { $0.name.lowercased() == "content-type" }?.value
                if PreviewURLMapping.isRewritable(contentType: type) {
                    held = Data()
                } else {
                    task.didReceive(Self.response(url: url, status: status, headers: headers))
                    sent = true
                }
            case .body(_, let data):
                if held != nil { held?.append(data) } else { task.didReceive(data) }
            case .end:
                if let held {
                    task.didReceive(Self.response(url: url, status: status, headers: headers))
                    task.didReceive(Self.rewritten(held))
                }
                task.didFinish()
                return .finished
            case .failure(_, let reason):
                // A reply already under way cannot be taken back, so it ends as a broken one.
                fail(task, key, URLError(sent ? .networkConnectionLost : .cannotConnectToHost), page: isPage && !sent ? reason : nil)
                return .finished
            }
        }
        // The stream ended with no verdict: the web view stopped waiting, or the link went away.
        if running[key] != nil { fail(task, key, URLError(.networkConnectionLost), page: isPage ? .disconnected : nil) }
        return .finished
    }

    // MARK: Pieces

    private func fail(_ task: any WKURLSchemeTask, _ key: ObjectIdentifier, _ error: URLError, page: PreviewFailure? = nil) {
        guard running[key] != nil else { return }
        if let page { onPageFailure(page) }
        task.didFailWithError(error)
    }

    /// A redirect of the page itself has to move the web view's address, which a scheme handler cannot do from inside a response, so it is a page that moves it.
    private func respondWithRedirect(to next: URL, task: any WKURLSchemeTask, key: ObjectIdentifier, url: URL) {
        guard running[key] != nil else { return }
        let target = next.absoluteString.replacingOccurrences(of: "\"", with: "%22")
        let html = "<!doctype html><meta charset=utf-8><script>location.replace(\"\(target)\")</script>"
        task.didReceive(Self.response(url: url, status: 200, headers: [PreviewHeader(name: "Content-Type", value: "text/html; charset=utf-8")]))
        task.didReceive(Data(html.utf8))
        task.didFinish()
    }

    private static func response(url: URL, status: Int, headers: [PreviewHeader]) -> URLResponse {
        var fields: [String: String] = [:]
        for header in headers {
            fields[header.name] = PreviewURLMapping.rewritingLoopbackURLs(in: header.value)
        }
        return HTTPURLResponse(url: url, statusCode: status, httpVersion: "HTTP/1.1", headerFields: fields)
            ?? URLResponse(url: url, mimeType: nil, expectedContentLength: -1, textEncodingName: nil)
    }

    /// Left as it came when it is too big to be worth reading or is not UTF-8.
    private static func rewritten(_ data: Data) -> Data {
        guard data.count <= PreviewProxyLimits.maxRewriteBytes, let text = String(data: data, encoding: .utf8) else { return data }
        return Data(PreviewURLMapping.rewritingLoopbackURLs(in: text).utf8)
    }

    private static func body(of request: URLRequest) -> Data? {
        if let body = request.httpBody { return body }
        guard let stream = request.httpBodyStream else { return nil }
        stream.open()
        defer { stream.close() }
        var data = Data()
        var buffer = [UInt8](repeating: 0, count: 16 * 1024)
        while stream.hasBytesAvailable, data.count <= PreviewProxyLimits.maxRequestBodyBytes {
            let count = stream.read(&buffer, maxLength: buffer.count)
            if count <= 0 { break }
            data.append(buffer, count: count)
        }
        return data
    }
}
