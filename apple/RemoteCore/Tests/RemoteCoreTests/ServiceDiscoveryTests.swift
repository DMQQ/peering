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
        // Two Macs can share a name, so the ordering must be deterministic or the list reshuffles under the user's finger.
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
        let a = host(id: "mac-1", name: "Laptop", port: 51515)
        let b = host(id: "mac-1", name: "Laptop", port: 60000)

        #expect(a == b)
        #expect(a.hashValue == b.hashValue)
        #expect(Set([a, b]).count == 1)
    }

    @Test("a rename is a change, so the picker refreshes")
    func renameIsAChange() {
        let a = host(id: "mac-1", name: "Old Name")
        let b = host(id: "mac-1", name: "New Name")

        #expect(a != b)
        #expect(Set([a, b]).count == 2)
    }

    @Test("equal hosts hash equally")
    func hashTracksEquality() {
        // Easy to break by adding a field to one of == or hash and not the other; the host then vanishes from a Set without an error.
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
        let collapsed = DiscoveredHost.collapse([host(id: "mac-1", name: "Laptop", version: nil)])

        #expect(collapsed.count == 1)
        #expect(collapsed[0].protocolVersion == nil)
    }

    private var endpoint: NWEndpoint {
        .hostPort(host: "127.0.0.1", port: NWEndpoint.Port(rawValue: ProtocolInfo.defaultPort)!)
    }

    @Test("a result with no device ID is not offered as a host")
    func dropsResultsThatAreNotHosts() {
        // `_remotedesktop._tcp` is Apple's Screen Sharing type, so Macs with no Peering device ID show up and must be dropped.
        #expect(DiscoveredHost.decode(endpoint: endpoint, txt: nil) == nil)
        #expect(DiscoveredHost.decode(endpoint: endpoint, txt: NWTXTRecord(["name": "Someone's Mac"])) == nil)
    }

    @Test("a device ID that is present but empty is not an identity")
    func dropsEmptyDeviceID() {
        #expect(DiscoveredHost.decode(endpoint: endpoint, txt: NWTXTRecord(["id": ""])) == nil)
    }

    @Test("a host that publishes only an ID is still connectable")
    func keepsHostWithMinimalTXTRecord() {
        let host = DiscoveredHost.decode(endpoint: endpoint, txt: NWTXTRecord(["id": "mac-1"]))

        #expect(host?.id == "mac-1")
        #expect(host?.protocolVersion == nil)
        #expect(host?.name.isEmpty == false)
    }

    @Test("the Bonjour service type carries the protocol it advertises")
    func serviceTypeMatchesProtocol() {
        // If these disagree the browse finds nothing, with no error to explain why.
        #expect(ProtocolInfo.bonjourServiceType == "_remotedesktop._tcp")
    }
}
