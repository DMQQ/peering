import Testing

@testable import MacCastKit

@Suite("What a Mac may make the phone remember")
struct HostRecordLimitsTests {
    @Test func aLongNameIsClipped() {
        let clipped = HostRecordLimits.clippedName(String(repeating: "m", count: 5_000))
        #expect(clipped.count == HostRecordLimits.maximumNameCharacters)
    }

    @Test func aShortNameIsUnchanged() {
        #expect(HostRecordLimits.clippedName("Studio") == "Studio")
    }

    @Test func manyAddressesAreCappedAndEachIsClipped() {
        let addresses = Array(repeating: String(repeating: "a", count: 100), count: 50)
        let clipped = HostRecordLimits.clippedMACAddresses(addresses)
        #expect(clipped.count == HostRecordLimits.maximumMACAddresses)
        #expect(clipped.allSatisfy { $0.count == HostRecordLimits.maximumMACCharacters })
    }

    @Test func aFullTableLosesOnlyUnpairedHosts() {
        var records: [String: String] = [:]
        for index in 0...HostRecordLimits.maximumHosts { records["host-\(index)"] = "name" }
        let pruned = HostRecordLimits.pruned(records, keeping: ["host-0", "host-1"])
        #expect(Set(pruned.keys) == ["host-0", "host-1"])
    }

    @Test func aTableWithinTheLimitIsKept() {
        let records = ["a": 1, "b": 2]
        #expect(HostRecordLimits.pruned(records, keeping: []) == records)
    }
}
