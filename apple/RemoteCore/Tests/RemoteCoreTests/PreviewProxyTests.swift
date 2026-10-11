import Foundation
import Testing

@testable import RemoteCore

@Suite struct PreviewProxyPolicyTests {
    private func request(
        port: UInt16 = 3000, method: String = "GET", target: String = "/", body: Data? = nil
    ) -> PreviewProxyRequest {
        PreviewProxyRequest(id: 1, port: port, method: method, target: target, body: body)
    }

    @Test func aPlainRequestOnAnOrdinaryPortIsServed() {
        #expect(PreviewProxyPolicy.refusal(for: request(target: "/a/b?c=1")) == nil)
    }

    @Test func theAppsOwnPortAndPortZeroAreRefused() {
        #expect(PreviewProxyPolicy.refusal(for: request(port: 51515)) == .notAllowed)
        #expect(PreviewProxyPolicy.refusal(for: request(port: 0)) == .notAllowed)
    }

    @Test func aMethodOutsideTheListIsRefused() {
        #expect(PreviewProxyPolicy.refusal(for: request(method: "CONNECT")) == .notAllowed)
        #expect(PreviewProxyPolicy.refusal(for: request(method: "get")) == .notAllowed)
    }

    @Test(arguments: ["", "x", "//evil.example/", "/a b", "/a\r\nHost: x", "/\\evil", "http://evil.example/"])
    func aTargetThatIsNotAPathIsRefused(target: String) {
        #expect(PreviewProxyPolicy.refusal(for: request(target: target)) == .invalidRequest)
    }

    @Test func anOversizedBodyIsRefused() {
        let body = Data(count: PreviewProxyLimits.maxRequestBodyBytes + 1)
        #expect(PreviewProxyPolicy.refusal(for: request(method: "POST", body: body)) == .tooLarge)
    }

    @Test func theDestinationIsAlwaysTheLoopbackAddress() {
        let url = PreviewProxyPolicy.destination(port: 5173, target: "/@vite/client?x=1")
        #expect(url?.host == "127.0.0.1")
        #expect(url?.port == 5173)
        #expect(PreviewProxyPolicy.destination(port: 5173, target: "/@evil.example/")?.host == "127.0.0.1")
        #expect(PreviewProxyPolicy.destination(port: 5173, target: "//evil.example/") == nil)
        #expect(PreviewProxyPolicy.destination(port: 51515, target: "/") == nil)
    }

    @Test(arguments: ["192.168.1.10", "10.0.0.2", "example.com", "0.0.0.0", "::1", "localhost.evil.example", "127.0.0.2"])
    func aHostThatIsNotLoopbackIsNotLoopback(host: String) {
        #expect(!PreviewProxyPolicy.isLoopbackHost(host))
    }

    @Test func requestHeadersKeepWhatAPageNeedsAndDropTheRest() {
        let kept = PreviewProxyPolicy.filteredRequestHeaders([
            PreviewHeader(name: "Accept", value: "text/html"),
            PreviewHeader(name: "X-CSRF-Token", value: "t"),
            PreviewHeader(name: "Host", value: "evil.example"),
            PreviewHeader(name: "Content-Length", value: "9"),
            PreviewHeader(name: "Connection", value: "upgrade"),
            PreviewHeader(name: "Accept", value: "a\r\nInjected: 1"),
        ])
        #expect(kept.map(\.name) == ["Accept", "X-CSRF-Token"])
    }

    @Test func originAndRefererGoBackToHTTP() {
        let kept = PreviewProxyPolicy.filteredRequestHeaders([
            PreviewHeader(name: "Origin", value: "peering-preview://localhost:3000"),
            PreviewHeader(name: "Referer", value: "peering-preview://localhost:3000/a"),
        ])
        #expect(kept.map(\.value) == ["http://localhost:3000", "http://localhost:3000/a"])
    }

    @Test func responseHeadersDropCookiesPoliciesAndFraming() {
        let kept = PreviewProxyPolicy.filteredResponseHeaders([
            PreviewHeader(name: "Content-Type", value: "text/html"),
            PreviewHeader(name: "Set-Cookie", value: "a=b"),
            PreviewHeader(name: "Content-Security-Policy", value: "default-src 'self'"),
            PreviewHeader(name: "Content-Encoding", value: "gzip"),
            PreviewHeader(name: "Content-Length", value: "10"),
            PreviewHeader(name: "Location", value: "/x"),
        ])
        #expect(kept.map(\.name) == ["Content-Type", "Location"])
    }
}

@Suite struct PreviewURLMappingTests {
    @Test(arguments: [
        ("3000", "peering-preview://localhost:3000/"),
        ("localhost:3000", "peering-preview://localhost:3000/"),
        ("127.0.0.1:5173/docs?a=1", "peering-preview://localhost:5173/docs?a=1"),
        ("http://localhost:8080/x", "peering-preview://localhost:8080/x"),
    ])
    func typedAddressesOnLoopbackAreTaken(typed: String, expected: String) {
        #expect(PreviewURLMapping.url(fromTyped: typed)?.absoluteString == expected)
    }

    @Test(arguments: [
        "192.168.1.5:3000", "http://example.com", "example.com:3000", "localhost", "localhost:99999",
        "http://localhost:3000@evil.example", "localhost:51515", "0", "", "http://user@localhost:3000",
    ])
    func typedAddressesOffLoopbackAreRefused(typed: String) {
        #expect(PreviewURLMapping.url(fromTyped: typed) == nil)
    }

    @Test func aPreviewURLParsesToPortAndTarget() throws {
        let url = try #require(URL(string: "peering-preview://localhost:3000/a%20b?q=1"))
        let parsed = PreviewURLMapping.parse(url)
        #expect(parsed?.port == 3000)
        #expect(parsed?.target == "/a%20b?q=1")
    }

    @Test func aPreviewURLNamingAnotherHostDoesNotParse() throws {
        #expect(PreviewURLMapping.parse(try #require(URL(string: "peering-preview://192.168.1.2:3000/"))) == nil)
        #expect(PreviewURLMapping.parse(try #require(URL(string: "https://localhost:3000/"))) == nil)
        #expect(PreviewURLMapping.parse(try #require(URL(string: "peering-preview://localhost/"))) == nil)
    }

    @Test func absoluteLoopbackURLsInAPageAreBroughtIntoTheScheme() {
        let page = #"<script src="http://localhost:3000/a.js"></script> fetch("//127.0.0.1:4000/api") https://example.com/x http://localhost/y"#
        let rewritten = PreviewURLMapping.rewritingLoopbackURLs(in: page)
        #expect(rewritten.contains(#"src="peering-preview://localhost:3000/a.js""#))
        #expect(rewritten.contains(#"fetch("peering-preview://localhost:4000/api")"#))
        #expect(rewritten.contains("https://example.com/x http://localhost/y"))
    }

    @Test func rewritingBackRestoresHTTP() {
        let text = PreviewURLMapping.restoringHTTPURLs(in: "peering-preview://localhost:3000/a")
        #expect(text == "http://localhost:3000/a")
    }

    @Test func onlyTextIsRewritten() {
        #expect(PreviewURLMapping.isRewritable(contentType: "text/html; charset=utf-8"))
        #expect(PreviewURLMapping.isRewritable(contentType: "application/javascript"))
        #expect(!PreviewURLMapping.isRewritable(contentType: "image/png"))
        #expect(!PreviewURLMapping.isRewritable(contentType: nil))
    }

    @Test func aRelativeRedirectStaysInsideTheScheme() throws {
        let from = try #require(URL(string: "peering-preview://localhost:3000/a/b"))
        #expect(PreviewURLMapping.redirect(status: 302, location: "/login", from: from)
            == .follow(try #require(URL(string: "peering-preview://localhost:3000/login"))))
    }

    @Test func aLoopbackRedirectIsBroughtIntoTheScheme() throws {
        let from = try #require(URL(string: "peering-preview://localhost:3000/"))
        #expect(PreviewURLMapping.redirect(status: 301, location: "http://localhost:3001/x?y=1", from: from)
            == .follow(try #require(URL(string: "peering-preview://localhost:3001/x?y=1"))))
    }

    @Test func aRedirectOffLoopbackIsRefused() throws {
        let from = try #require(URL(string: "peering-preview://localhost:3000/"))
        #expect(PreviewURLMapping.redirect(status: 302, location: "https://example.com/", from: from) == .refuse)
        #expect(PreviewURLMapping.redirect(status: 302, location: "http://192.168.1.4:3000/", from: from) == .refuse)
    }

    @Test func aPageIsShownUnderItsLoopbackAddress() throws {
        let url = try #require(URL(string: "peering-preview://localhost:3000/docs?a=1"))
        #expect(PreviewURLMapping.displayAddress(for: url) == "localhost:3000/docs?a=1")
        #expect(PreviewURLMapping.displayAddress(for: try #require(URL(string: "https://example.com"))) == nil)
    }

    @Test func aLinkToAnotherHostOrAPortlessLoopbackHasNoPreviewTwin() throws {
        #expect(PreviewURLMapping.previewURL(forLoopback: try #require(URL(string: "http://localhost/"))) == nil)
        #expect(PreviewURLMapping.previewURL(forLoopback: try #require(URL(string: "http://example.com:3000/"))) == nil)
        #expect(PreviewURLMapping.previewURL(forLoopback: try #require(URL(string: "http://localhost:3000/a")))?.absoluteString
            == "peering-preview://localhost:3000/a")
    }

    @Test func aNonRedirectIsLeftAlone() throws {
        let from = try #require(URL(string: "peering-preview://localhost:3000/"))
        #expect(PreviewURLMapping.redirect(status: 200, location: "/x", from: from) == .notARedirect)
        #expect(PreviewURLMapping.redirect(status: 304, location: nil, from: from) == .notARedirect)
    }
}

@Suite struct PreviewWireTests {
    @Test func aFetchSurvivesTheWire() throws {
        let command = PreviewProxyCommand.fetch(PreviewProxyRequest(
            id: 7, port: 3000, method: "POST", target: "/x?y=1",
            headers: [PreviewHeader(name: "Content-Type", value: "application/json")], body: Data([1, 2, 3])
        ))
        let decoded = try MessageCodec.decode(PreviewProxyCommand.self, from: try MessageCodec.encode(command))
        #expect(decoded == command)
    }

    @Test func everyEventSurvivesTheWire() throws {
        let events: [PreviewProxyEvent] = [
            .head(id: 1, status: 200, headers: [PreviewHeader(name: "A", value: "b")]),
            .body(id: 1, data: Data([9, 8])),
            .end(id: 1, truncated: true),
            .failure(id: 2, reason: .notListening),
        ]
        for event in events {
            #expect(try MessageCodec.decode(PreviewProxyEvent.self, from: try MessageCodec.encode(event)) == event)
        }
    }

    @Test func aFullChunkStaysUnderTheFrameLimit() throws {
        let event = PreviewProxyEvent.body(id: 1, data: Data(count: PreviewProxyLimits.chunkBytes))
        #expect(try MessageCodec.encode(event).count < 128 * 1024)
    }

    @Test func aFullRequestFitsTheRequestFrameLimit() throws {
        let command = PreviewProxyCommand.fetch(PreviewProxyRequest(
            id: 1, port: 3000, method: "POST", target: "/", body: Data(count: PreviewProxyLimits.maxRequestBodyBytes)
        ))
        #expect(try MessageCodec.encode(command).count < PreviewProxyLimits.maxRequestFrameBytes)
    }

    @Test func theKindsAreDeclared() {
        #expect(MessageKind.allCases.contains(.previewRequest))
        #expect(MessageKind.allCases.contains(.previewEvent))
    }

    @Test func aFinalEventClosesTheRequestAndBodiesDoNot() {
        #expect(PreviewProxyEvent.end(id: 1, truncated: false).isFinal)
        #expect(PreviewProxyEvent.failure(id: 1, reason: .failed).isFinal)
        #expect(!PreviewProxyEvent.body(id: 1, data: Data()).isFinal)
    }
}
