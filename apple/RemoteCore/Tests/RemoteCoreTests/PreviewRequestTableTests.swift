import Foundation
import Testing

@testable import RemoteCore

@Suite("Preview requests that nobody reads")
struct PreviewRequestTableTests {
    @Test func aStreamNobodyReadsIsEndedInsteadOfGrowingForever() async {
        let table = PreviewRequestTable()
        let (stream, continuation) = AsyncStream<PreviewProxyEvent>.makeStream(
            bufferingPolicy: .bufferingOldest(2)
        )
        let id = table.register(continuation)
        for _ in 0..<5 { table.deliver(.body(id: id, data: Data([1]))) }

        var received = 0
        for await _ in stream { received += 1 }
        #expect(received == 2)
    }
}
