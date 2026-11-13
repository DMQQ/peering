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
        guard errorCode == kDNSServiceErr_NoError, address != 0, port != 0 else {
            mappingLog.notice("the router gave no port mapping (\(errorCode, privacy: .public))")
            onChange(nil)
            return
        }
        var raw = in_addr(s_addr: address)
        var text = [CChar](repeating: 0, count: Int(INET_ADDRSTRLEN))
        guard inet_ntop(AF_INET, &raw, &text, socklen_t(text.count)) != nil else { return }
        let host = String(cString: text)
        guard DirectCandidates.isPubliclyRoutable(ipv4: host) else {
            mappingLog.notice("the router's address is not reachable from the internet, so it is not announced")
            onChange(nil)
            return
        }
        let mapped = "\(host):\(UInt16(bigEndian: port))"
        mappingLog.notice("the router forwards \(mapped, privacy: .public) to this Mac")
        onChange(mapped)
    }
}
