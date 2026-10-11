import Foundation
import Testing

@testable import MacCastKit

@Suite struct AgentControlRequestsTests {
    private func object(_ line: String) -> [String: Any] {
        (try? JSONSerialization.jsonObject(with: Data(line.utf8)) as? [String: Any]) ?? [:]
    }

    private func requestID(_ line: String) -> String {
        object(line)["request_id"] as? String ?? ""
    }

    private func response(id: String, subtype: String, body: [String: Any] = [:], error: String? = nil) -> String {
        var inner: [String: Any] = ["subtype": subtype, "request_id": id, "response": body]
        if let error { inner["error"] = error }
        return AgentControlRequests.encode(["type": "control_response", "response": inner]) ?? ""
    }

    @Test func aRequestCarriesItsSubtypeAndFields() {
        var requests = AgentControlRequests()
        let line = requests.make(subtype: "set_model", fields: ["model": "sonnet"])
        let body = object(line ?? "")["request"] as? [String: Any]
        #expect(body?["subtype"] as? String == "set_model")
        #expect(body?["model"] as? String == "sonnet")
    }

    @Test func aSuccessReachesItsOwnCompletionWithTheBody() {
        var requests = AgentControlRequests()
        var model: String?
        let line = requests.make(subtype: "set_model") { outcome in
            if case .success(let body) = outcome { model = body?["model"] as? String }
        }
        let handled = requests.resolve(line: response(id: requestID(line ?? ""), subtype: "success", body: ["model": "full-name"]))
        #expect(handled == true)
        #expect(model == "full-name")
    }

    @Test func aFailureCarriesTheCLIsSentence() {
        var requests = AgentControlRequests()
        var message: String??
        let line = requests.make(subtype: "set_model") { outcome in
            if case .failure(let text) = outcome { message = .some(text) }
        }
        _ = requests.resolve(line: response(id: requestID(line ?? ""), subtype: "error", error: "no such model"))
        #expect(message == .some("no such model"))
    }

    @Test func twoRequestsInFlightEachGetTheirOwnAnswer() {
        var requests = AgentControlRequests()
        var answered: [String] = []
        let first = requests.make(subtype: "a") { _ in answered.append("a") }
        let second = requests.make(subtype: "b") { _ in answered.append("b") }
        _ = requests.resolve(line: response(id: requestID(second ?? ""), subtype: "success"))
        _ = requests.resolve(line: response(id: requestID(first ?? ""), subtype: "success"))
        #expect(answered == ["b", "a"])
    }

    @Test func someoneElsesResponseIsNotOurs() {
        var requests = AgentControlRequests()
        _ = requests.make(subtype: "a") { _ in }
        let foreign = requests.resolve(line: response(id: "other", subtype: "success"))
        let assistant = requests.resolve(line: "{\"type\":\"assistant\"}")
        let garbage = requests.resolve(line: "garbage")
        #expect(!foreign && !assistant && !garbage)
    }

    @Test func aRequestWithoutACompletionIsNotTracked() {
        var requests = AgentControlRequests()
        let line = requests.make(subtype: "interrupt")
        let handled = requests.resolve(line: response(id: requestID(line ?? ""), subtype: "success"))
        #expect(!handled)
    }
}
