import Foundation
import Network
import Testing

@testable import RemoteCore

@Suite("Discovered host")
struct ServiceDiscoveryTests {
    private func host(
        id: String,
        name: String,
        port: UInt16 = ProtocolInfo.defaultPort,
        version: UInt16? = ProtocolInfo.version
    ) -> DiscoveredHost {
        DiscoveredHost(
            id: id,
            name: name,
            endpoint: .hostPort(host: "127.0.0.1", port: NWEndpoint.Port(rawValue: port)!),
            protocolVersion: version,
            interfaceCount: 1
        )
    }

    @Test("a host found on two interfaces is listed once")
    func collapsesDuplicateInterfaces() {
        // The same Mac seen over Wi-Fi and Ethernet. Showing it twice would present the
        // user with a choice that has no meaningful difference between its options.
        let collapsed = DiscoveredHost.collapse([
            host(id: "mac-1", name: "Damian's MacBook Pro"),
            host(id: "mac-1", name: "Damian's MacBook Pro"),
        ])

        #expect(collapsed.count == 1)
        #expect(collapsed[0].interfaceCount == 2)
    }

    @Test("distinct hosts are all kept")
    func keepsDistinctHosts() {
        let collapsed = DiscoveredHost.collapse([
            host(id: "mac-1", name: "Laptop"),
            host(id: "mac-2", name: "Studio"),
        ])

        #expect(collapsed.count == 2)
        #expect(collapsed.map(\.id) == ["mac-1", "mac-2"])
        #expect(collapsed.allSatisfy { $0.interfaceCount == 1 })
    }

    @Test("sorts by name, and by ID when names tie")
    func sortsForDisplay() {
        // Two Macs can genuinely share a name — a default "MacBook Pro" on two machines —
        // so the ordering has to stay deterministic rather than depending on discovery
        // order, or the list reshuffles itself under the user's finger.
        let collapsed = DiscoveredHost.collapse([
            host(id: "b", name: "MacBook Pro"),
            host(id: "a", name: "MacBook Pro"),
            host(id: "z", name: "Anna's iMac"),
        ])

        #expect(collapsed.map(\.id) == ["z", "a", "b"])
    }

    @Test("collapsing an empty list is empty")
    func collapsesEmpty() {
        #expect(DiscoveredHost.collapse([]).isEmpty)
    }

    @Test("the same host on a different endpoint is not a change")
    func endpointDoesNotAffectEquality() {
        // The endpoint is where the host was found this time, not part of what the picker
        // shows. Comparing it would make the browser re-emit an identical list on every
        // re-discovery — a repaint the user can see on a busy network.
        let a = host(id: "mac-1", name: "Laptop", port: 51515)
        let b = host(id: "mac-1", name: "Laptop", port: 60000)

        #expect(a == b)
        #expect(a.hashValue == b.hashValue)
        #expect(Set([a, b]).count == 1)
    }

    @Test("a rename is a change, so the picker refreshes")
    func renameIsAChange() {
        // The counterpart to the test above, and the reason equality is not simply the
        // device ID: the browser suppresses updates that compare equal, so a host the user
        // has renamed would keep showing its old name until something else changed.
        let a = host(id: "mac-1", name: "Old Name")
        let b = host(id: "mac-1", name: "New Name")

        #expect(a != b)
        #expect(Set([a, b]).count == 2)
    }

    @Test("equal hosts hash equally")
    func hashTracksEquality() {
        // The contract that makes Set<DiscoveredHost> safe. Easy to break by adding a field
        // to one of == or hash and not the other, and the failure is a host that randomly
        // disappears from a Set rather than an outright error.
        let a = host(id: "mac-1", name: "Laptop", version: 3)
        let b = host(id: "mac-1", name: "Laptop", version: 3)

        #expect(a == b)
        #expect(a.hashValue == b.hashValue)
    }

    @Test("the protocol version survives collapsing")
    func keepsProtocolVersion() {
        let collapsed = DiscoveredHost.collapse([
            host(id: "mac-1", name: "Laptop", version: 1),
            host(id: "mac-1", name: "Laptop", version: 1),
        ])

        #expect(collapsed[0].protocolVersion == 1)
    }

    @Test("a host with no published version is kept, not dropped")
    func toleratesMissingVersion() {
        // A host that publishes less than expected should still be listed and connectable.
        // Hiding it would turn a cosmetic TXT-record omission into an unreachable device.
        let collapsed = DiscoveredHost.collapse([host(id: "mac-1", name: "Laptop", version: nil)])

        #expect(collapsed.count == 1)
        #expect(collapsed[0].protocolVersion == nil)
    }

    @Test("the Bonjour service type carries the protocol it advertises")
    func serviceTypeMatchesProtocol() {
        // Bound into the advertised type, the Info.plist key, and the browser's descriptor.
        // If these ever disagree the browse simply finds nothing, with no error to explain
        // why — so the shared constant is the only thing keeping them together.
        #expect(ProtocolInfo.bonjourServiceType == "_remotedesktop._tcp")
    }
}
