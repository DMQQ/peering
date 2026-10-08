import Foundation
import Network
import RemoteCore

enum RememberedLANHosts {
    private static let key = "Peering.rememberedLANHosts"

    private struct Stored: Codable {
        var name: String
        var serviceName: String?
        var serviceType: String?
        var serviceDomain: String?
        var host: String?
        var port: UInt16?
        var protocolVersion: UInt16?
        var interfaceCount: Int
    }

    static func load() -> [String: DiscoveredHost] {
        guard let data = UserDefaults.standard.data(forKey: key),
              let stored = try? JSONDecoder().decode([String: Stored].self, from: data)
        else { return [:] }
        var hosts: [String: DiscoveredHost] = [:]
        for (id, entry) in stored {
            let endpoint: NWEndpoint
            if let name = entry.serviceName, let type = entry.serviceType {
                endpoint = .service(name: name, type: type, domain: entry.serviceDomain ?? "local.", interface: nil)
            } else if let host = entry.host, let port = entry.port.flatMap(NWEndpoint.Port.init(rawValue:)) {
                endpoint = .hostPort(host: NWEndpoint.Host(host), port: port)
            } else {
                continue
            }
            hosts[id] = DiscoveredHost(
                id: id,
                name: entry.name,
                endpoint: endpoint,
                protocolVersion: entry.protocolVersion,
                interfaceCount: entry.interfaceCount
            )
        }
        return hosts
    }

    static func save(_ hosts: [String: DiscoveredHost]) {
        var stored: [String: Stored] = [:]
        for (id, host) in hosts {
            var entry = Stored(name: host.name, protocolVersion: host.protocolVersion, interfaceCount: host.interfaceCount)
            switch host.endpoint {
            case .service(let name, let type, let domain, _):
                entry.serviceName = name
                entry.serviceType = type
                entry.serviceDomain = domain
            case .hostPort(let address, let port):
                entry.host = "\(address)"
                entry.port = port.rawValue
            default:
                continue
            }
            stored[id] = entry
        }
        guard let data = try? JSONEncoder().encode(stored) else { return }
        UserDefaults.standard.set(data, forKey: key)
    }
}
