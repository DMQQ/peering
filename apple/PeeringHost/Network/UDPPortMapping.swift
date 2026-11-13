import Foundation
import RemoteCore
import dnssd
import os

private let mappingLog = Logger(subsystem: "pl.dmq.peering.host", category: "port-mapping")

/// Asks the router to forward a UDP port to this Mac, over UPnP, NAT-PMP or PCP (the system speaks all three), and reports the public `host:port` it was given. A client can send to that address with no hole punched, which is what a client behind a NAT that will not punch needs.
final class UDPPortMapping: @unchecked Sendable {
    private let internalPort: UInt16
    private let onChange: @Sendable (String?) -> Void
    private let queue = DispatchQueue(label: "pl.dmq.peering.host.port-mapping")
    /// Touched only on `queue`.
    private var service: DNSServiceRef?

    init(internalPort: UInt16, onChange: @escaping @Sendable (String?) -> Void) {
        self.internalPort = internalPort
        self.onChange = onChange
    }

    deinit { release() }

    func start() {
        queue.async { [self] in
            guard service == nil else { return }
            var created: DNSServiceRef?
            let status = DNSServiceNATPortMappingCreate(
                &created, 0, 0, DNSServiceProtocol(kDNSServiceProtocol_UDP),
                internalPort.bigEndian, 0, 0,
                { @Sendable _, _, _, errorCode, externalAddress, _, _, externalPort, _, context in
                    guard let context else { return }
                    Unmanaged<UDPPortMapping>.fromOpaque(context).takeUnretainedValue()
                        .answered(errorCode: errorCode, address: externalAddress, port: externalPort)
                },
                Unmanaged.passUnretained(self).toOpaque()
            )
            guard status == kDNSServiceErr_NoError, let created else {
                mappingLog.error("could not ask the router for a port mapping: \(status, privacy: .public)")
                return
            }
            DNSServiceSetDispatchQueue(created, queue)
            service = created
        }
    }

    func stop() {
        queue.sync { release() }
    }

    private func release() {
        guard let service else { return }
        DNSServiceRefDeallocate(service)
        self.service = nil
    }

    private func answered(errorCode: DNSServiceErrorType, address: UInt32, port: UInt16) {
        guard let mapped = DirectCandidates.mappedCandidate(errorCode: errorCode, externalAddress: address, externalPort: port) else {
            mappingLog.notice("the router gave no usable port mapping (code \(errorCode, privacy: .public))")
            onChange(nil)
            return
        }
        mappingLog.notice("the router forwards \(mapped, privacy: .public) to this Mac")
        onChange(mapped)
    }
}
