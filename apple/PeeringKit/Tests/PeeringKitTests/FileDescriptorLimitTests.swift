import Testing

@testable import PeeringKit

struct FileDescriptorLimitTests {
    @Test func aLowSoftLimitIsRaisedToWhatIsWanted() {
        #expect(FileDescriptorLimit.target(soft: 256, hard: 100_000, wanted: 8192) == 8192)
    }

    @Test func theHardLimitIsNeverExceeded() {
        #expect(FileDescriptorLimit.target(soft: 256, hard: 1024, wanted: 8192) == 1024)
    }

    @Test func anAlreadySufficientLimitIsLeftAlone() {
        #expect(FileDescriptorLimit.target(soft: 10_240, hard: 100_000, wanted: 8192) == nil)
        #expect(FileDescriptorLimit.target(soft: 1024, hard: 1024, wanted: 8192) == nil)
    }
}
