import Foundation
import Testing

@testable import PeeringKit

@Suite("What an error report carries")
struct ErrorDetailTests {
    private enum Sample: Error {
        case bare
        case withDetail(String)
    }

    @Test("an enum case is named without its payload")
    func caseWithoutPayload() {
        let details = ErrorDetail.properties(for: Sample.withDetail("/Users/someone/secret.txt"))
        #expect(details["error_case"] == "withDetail")
        #expect(!details.values.contains { $0.contains("secret") })
    }

    @Test("a case with no payload is named as is")
    func bareCase() {
        #expect(ErrorDetail.properties(for: Sample.bare)["error_case"] == "bare")
    }

    @Test("a system error carries its domain and code only")
    func systemError() {
        let details = ErrorDetail.properties(for: NSError(domain: NSURLErrorDomain, code: -1009))
        #expect(details["error_domain"] == NSURLErrorDomain)
        #expect(details["error_code"] == "-1009")
        #expect(details["error_case"] == nil)
    }

    @Test("the errors wrapped inside one are listed outermost first")
    func underlyingChain() {
        let root = NSError(domain: NSPOSIXErrorDomain, code: 57)
        let middle = NSError(domain: NSURLErrorDomain, code: -1200, userInfo: [NSUnderlyingErrorKey: root])
        let outer = NSError(domain: "SUSparkleErrorDomain", code: 2001, userInfo: [NSUnderlyingErrorKey: middle])
        let details = ErrorDetail.properties(for: outer)
        #expect(details["error_underlying"] == "NSURLErrorDomain:-1200 > NSPOSIXErrorDomain:57")
    }

    @Test("an error with nothing inside it has no underlying entry")
    func noUnderlying() {
        #expect(ErrorDetail.properties(for: NSError(domain: "Sample", code: 1))["error_underlying"] == nil)
    }
}
