import Foundation
import Network

/// The advertised name is an unauthenticated hint: nothing security-relevant may be decided from these values. Identification happens in the TLS handshake and pin check.
public struct DiscoveredHost: Sendable, Identifiable {
    /// The host's persistent device ID from its TXT record; stable across networks and renames, so it is the identity.
    public let id: String

    public let name: String

    /// Connect to this directly: a Bonjour endpoint carries its discovery interface, whereas resolving to an address first can pick the wrong one.
    public let endpoint: NWEndpoint

    /// From the TXT record; lets the client grey out an incompatible host.
    public let protocolVersion: UInt16?

    public let interfaceCount: Int

    public init(
        id: String,
        name: String,
        endpoint: NWEndpoint,
        protocolVersion: UInt16?,
        interfaceCount: Int
    ) {
        self.id = id
        self.name = name
        self.endpoint = endpoint
        self.protocolVersion = protocolVersion
        self.interfaceCount = interfaceCount
    }

    /// Excludes the endpoint: ``HostBrowser`` re-emits only when a rename or protocol version changes, not a new interface alone.
    public static func == (lhs: DiscoveredHost, rhs: DiscoveredHost) -> Bool {
        lhs.id == rhs.id
            && lhs.name == rhs.name
            && lhs.protocolVersion == rhs.protocolVersion
            && lhs.interfaceCount == rhs.interfaceCount
    }
}

extension DiscoveredHost: Hashable {
    public func hash(into hasher: inout Hasher) {
        hasher.combine(id)
        hasher.combine(name)
        hasher.combine(protocolVersion)
        hasher.combine(interfaceCount)
    }
}

extension DiscoveredHost {
    /// Merges the per-interface entries of one machine (Wi-Fi and Ethernet), keeping the interface count, and orders for display.
    public static func collapse(_ hosts: [DiscoveredHost]) -> [DiscoveredHost] {
        var order: [String] = []
        var byID: [String: DiscoveredHost] = [:]
        var interfaces: [String: Int] = [:]

        for host in hosts {
            interfaces[host.id, default: 0] += 1
            guard byID[host.id] == nil else { continue }
            byID[host.id] = host
            order.append(host.id)
        }

        return order.compactMap { id in
            guard let host = byID[id] else { return nil }
            return DiscoveredHost(
                id: host.id,
                name: host.name,
                endpoint: host.endpoint,
                protocolVersion: host.protocolVersion,
                interfaceCount: interfaces[id] ?? 1
            )
        }
        .sorted { ($0.name, $0.id) < ($1.name, $1.id) }
    }

    /// Builds a host from a browse result, or nil if it is not a MacCast host. `_remotedesktop._tcp` is Apple's Screen Sharing type, so other Macs appear too; the device ID (required, since the pin and handshake key on it) tells them apart.
    static func decode(endpoint: NWEndpoint, txt: NWTXTRecord?) -> DiscoveredHost? {
        // An empty `id=` is malformed, and all of them would collapse to one host.
        guard let id = txt?[ProtocolInfo.TXTRecordKey.deviceID], !id.isEmpty else { return nil }

        return DiscoveredHost(
            id: id,
            name: txt?[ProtocolInfo.TXTRecordKey.deviceName] ?? endpoint.debugDescription,
            endpoint: endpoint,
            protocolVersion: txt?[ProtocolInfo.TXTRecordKey.protocolVersion].flatMap(UInt16.init),
            interfaceCount: 1
        )
    }
}

/// Reports the complete current list on every change rather than deltas: `NWBrowser` already gives the full set, and diffing twice is how a stale Mac lingers.
public final class HostBrowser: @unchecked Sendable {
    public enum Event: Sendable {
        case started
        case updated([DiscoveredHost])
        case failed(String)
    }

    private let queue = DispatchQueue(label: "pl.dmq.peering.browse")
    private let callbackLock = NSLock()
    private var _onEvent: (@Sendable (Event) -> Void)?

    private var browser: NWBrowser?
    private var current: [DiscoveredHost] = []

    /// Distinguishes a browse that died from one put away, so ``stop()`` is not undone by a restart.
    private var isRunning = false

    private var restartAttempt = 0

    /// Bumped by a deliberate stop so an in-flight restart (a closure, not a task) can tell it was called off.
    private var restartGeneration = 0

    /// Short at first (the usual failure is the daemon dropping us on a network change), capped so Wi-Fi off settles into a retry every half minute.
    private static let restartDelays: [TimeInterval] = [1, 2, 5, 10, 20, 30]

    public var onEvent: (@Sendable (Event) -> Void)? {
        get { callbackLock.withLock { _onEvent } }
        set { callbackLock.withLock { _onEvent = newValue } }
    }

    public init() {}

    public func start() {
        queue.async { [weak self] in
            guard let self else { return }
            self.isRunning = true
            guard self.browser == nil else { return }

            let parameters = NWParameters()
            // Peer-to-peer would add AWDL and surface Macs on no shared network.
            parameters.includePeerToPeer = false

            // `bonjourWithTXTRecord`, not `bonjour`: with the plain case the result metadata is
            // `.none` and the device ID never arrives, so pinning has nothing consistent to key on.
            let descriptor = NWBrowser.Descriptor.bonjourWithTXTRecord(
                type: ProtocolInfo.bonjourServiceType,
                domain: nil
            )
            let browser = NWBrowser(for: descriptor, using: parameters)

            browser.stateUpdateHandler = { [weak self] state in
                guard let self else { return }
                switch state {
                case .ready:
                    self.restartAttempt = 0
                    self.emit(.started)
                case .failed(let error):
                    // An `NWError`'s own `localizedDescription` is `Network.NWError error 60`, not a sentence.
                    self.emit(.failed(NetworkFailureText.describe(error)))
                    self.replaceFailedBrowser()
                case .cancelled:
                    self.emit(.updated([]))
                default:
                    break
                }
            }

            browser.browseResultsChangedHandler = { [weak self] results, _ in
                self?.rebuild(from: results)
            }

            self.browser = browser
            browser.start(queue: queue)
        }
    }

    public func stop() {
        queue.async { [weak self] in
            guard let self else { return }
            self.isRunning = false
            self.restartGeneration += 1
            self.teardown()
        }
    }

    private func teardown() {
        // Nil both handlers before cancelling: .cancelled fires asynchronously on this queue after
        // cancel() returns, and a handler still pointing here would wipe a new browser's results.
        browser?.stateUpdateHandler = nil
        browser?.browseResultsChangedHandler = nil
        browser?.cancel()
        browser = nil
        current = []
    }

    /// `DefunctConnection` is the daemon dropping us (Wi-Fi change, daemon restart, backgrounding); only a new browser cures it.
    private func replaceFailedBrowser() {
        teardown()
        guard isRunning else { return }

        let delay = Self.restartDelays[min(restartAttempt, Self.restartDelays.count - 1)]
        restartAttempt += 1
        let generation = restartGeneration
        queue.asyncAfter(deadline: .now() + delay) { [weak self] in
            guard let self, self.restartGeneration == generation, self.isRunning else { return }
            self.start()
        }
    }

    // MARK: - Result handling

    private func rebuild(from results: Set<NWBrowser.Result>) {
        let hosts = DiscoveredHost.collapse(results.compactMap { result in
            let txt: NWTXTRecord? = {
                if case .bonjour(let record) = result.metadata { return record }
                return nil
            }()

            return DiscoveredHost.decode(endpoint: result.endpoint, txt: txt)
        })

        guard hosts != current else { return }
        current = hosts
        emit(.updated(hosts))
    }

    private func emit(_ event: Event) {
        onEvent?(event)
    }
}
