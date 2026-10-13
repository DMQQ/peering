import Testing

@testable import PeeringKit

struct PreAuthAdmissionTests {
    @Test func aFirstConnectionIsAdmitted() {
        #expect(PreAuthAdmission.decide(unauthenticatedAddresses: [], newAddress: "10.0.0.2") == .admit)
    }

    @Test func aThirdConnectionFromOneAddressIsRefused() {
        let existing = ["10.0.0.2", "10.0.0.2"]
        #expect(PreAuthAdmission.decide(unauthenticatedAddresses: existing, newAddress: "10.0.0.2") == .tooManyFromAddress)
        #expect(PreAuthAdmission.decide(unauthenticatedAddresses: existing, newAddress: "10.0.0.3") == .admit)
    }

    @Test func aNinthConnectionIsRefusedWhoeverItComesFrom() {
        let existing = (0..<8).map { "10.0.0.\($0)" }
        #expect(PreAuthAdmission.decide(unauthenticatedAddresses: existing, newAddress: "10.0.1.1") == .tooManyInTotal)
    }

    @Test func theTotalCapIsReportedBeforeTheAddressCap() {
        let existing = Array(repeating: "10.0.0.2", count: 2) + (3..<9).map { "10.0.0.\($0)" }
        #expect(PreAuthAdmission.decide(unauthenticatedAddresses: existing, newAddress: "10.0.0.2") == .tooManyInTotal)
    }
}
