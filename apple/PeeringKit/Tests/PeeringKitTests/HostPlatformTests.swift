import Foundation
import Testing

@testable import PeeringKit

struct HostPlatformTests {
    @Test func missingOrUnknownPlatformIsAMac() {
        #expect(HostPlatform(wireName: nil) == .mac)
        #expect(HostPlatform(wireName: "beos") == .mac)
        #expect(HostPlatform(wireName: "windows") == .windows)
        #expect(HostPlatform(wireName: "macos") == .mac)
    }

    @Test func aMacKeepsItsSentenceUntouched() {
        #expect(HostPlatform.mac.adapt("The Mac closed the connection.") == "The Mac closed the connection.")
    }

    @Test func windowsSwapsTheWordMacAndItsPlural() {
        #expect(HostPlatform.windows.adapt("The Mac closed the connection.") == "The PC closed the connection.")
        #expect(HostPlatform.windows.adapt("Paired Macs were reset. Pair each Mac again.") == "Paired PCs were reset. Pair each PC again.")
        #expect(HostPlatform.windows.adapt("Dem Mac fehlt es an Speicher.") == "Dem PC fehlt es an Speicher.")
    }

    @Test func windowsLeavesWordsThatOnlyContainMac() {
        #expect(HostPlatform.windows.adapt("Open macOS settings on a MacBook") == "Open macOS settings on a MacBook")
    }

    @Test func memoryReturnsWhatWasRemembered() throws {
        let suite = "HostPlatformMemoryTests-\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let memory = HostPlatformMemory(defaults: defaults)
        #expect(memory.platform(forHostID: "a") == .mac)
        memory.remember(.windows, forHostID: "a")
        #expect(memory.platform(forHostID: "a") == .windows)
        #expect(memory.platform(forHostID: "b") == .mac)
        #expect(memory.platform(forHostID: nil) == .mac)
    }
}
