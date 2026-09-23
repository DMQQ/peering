import Foundation
import Network

/// A host found by browsing Bonjour.
///
/// The advertised name is a hint, what the host called itself when it registered, and is not
/// authenticated in any way: nothing security-relevant may be decided from these values. Real
/// identification happens in the TLS handshake and the pin check.
public struct DiscoveredHost: Sendable, Identifiable {
    /// The host's persistent device ID, from its TXT record. Stable across networks, DHCP leases,
    /// and renames, which is why it is the identity and the advertised address is not.
    public let id: String

    /// The human-readable name the host advertised.
    public let name: String

    /// Connect to this directly rather than resolving to a host and port. A Bonjour endpoint
    /// carries the interface it was discovered on, so connecting through it uses the path that
    /// works; resolving to an address first can pick the wrong interface on a machine with several.
    public let endpoint: NWEndpoint

    /// The protocol version from the TXT record, if the host published one. Lets the
    /// client grey out an incompatible host instead of failing after a connect attempt.
    public let protocolVersion: UInt16?

    /// Whether the host reported being reachable on more than one interface.
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

    /// Equality covers everything the device picker renders, and excludes the endpoint.
    ///
    /// ``HostBrowser`` uses this to decide whether a browse update is worth re-emitting: a rename
    /// or a new protocol version must compare unequal, a new interface by itself must not.
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
    /// Collapses entries that describe the same host, and orders them for display.
    ///
    /// A Mac reachable over both Wi-Fi and Ethernet is discovered once per interface; both entries
    /// are the same machine and either works, so they are merged rather than listed several times.
    /// The interface count is kept so a multi-homed host can be shown as such.
    ///
    /// The survivor is the first entry seen for an ID, which is a stable choice: they are
    /// interchangeable.
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

    /// Builds a host from one browse result, or `nil` if that result is not a MacCast host.
    ///
    /// The service type is `_remotedesktop._tcp`, Apple's own Screen Sharing type, so the browser
    /// also returns every Mac on the network with Screen Sharing switched on.
    ///
    /// The device ID is what separates the two, and it is required: the pin, the stored host and
    /// the handshake all key on it, so a host publishing no ID could not be paired with. A display
    /// name and a protocol version are not needed to connect.
    static func decode(endpoint: NWEndpoint, txt: NWTXTRecord?) -> DiscoveredHost? {
        // An empty string is treated as absent: `id=` is a malformed advertisement rather than an
        // identity, and every one of them would collapse to the same host.
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

/// Browses for MacCast hosts on the local network.
///
/// Reports the complete current list on every change rather than found/lost deltas: `NWBrowser`
/// already hands over the full result set, so a delta API would mean diffing twice, and getting it
/// wrong in one of those places is how a picker shows a Mac that went to sleep an hour ago.
public final class HostBrowser: @unchecked Sendable {
    public enum Event: Sendable {
        case started
        /// The complete list, sorted by name, with each host appearing once.
        case updated([DiscoveredHost])
        case failed(String)
    }

    private let queue = DispatchQueue(label: "pl.dmq.peering.browse")
    private let callbackLock = NSLock()
    private var _onEvent: (@Sendable (Event) -> Void)?

    private var browser: NWBrowser?
    private var current: [DiscoveredHost] = []

    /// Whether a browser is wanted right now.
    ///
    /// Distinguishes a browse that died from one that was put away: only the first is worth
    /// replacing, and after ``stop()`` a restart would resurrect something the caller had finished
    /// with.
    private var isRunning = false

    /// How many restarts have been scheduled back to back, reset by a browser reaching `.ready`.
    private var restartAttempt = 0

    /// Bumped by a deliberate stop, so a restart already in flight can tell it has been called off.
    /// Compared rather than cancelled: what is pending is a closure on this queue, not a task.
    private var restartGeneration = 0

    /// How long to wait before replacing a browser that failed.
    ///
    /// Short at first: the common failure is the daemon dropping us during a network change and is
    /// over before the first retry runs. Capped so a device with Wi-Fi switched off settles into a
    /// retry every half minute instead of spinning.
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
            // Peer-to-peer would add AWDL and surface nearby Macs that are on no shared network,
            // which this app cannot connect to anyway.
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
                    // Through the shared table like every other network failure: an `NWError`'s
                    // own `localizedDescription` is `Network.NWError error 60`, not a sentence.
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

    /// Tears the current browser down. Must run on ``queue``.
    private func teardown() {
        // Nil both handlers before cancelling: .cancelled fires asynchronously on this queue after
        // cancel() returns, and a handler still pointing here would wipe a new browser's results.
        browser?.stateUpdateHandler = nil
        browser?.browseResultsChangedHandler = nil
        browser?.cancel()
        browser = nil
        current = []
    }

    /// Replaces a browser that died, because a browse that failed is not a network that has been
    /// proven wrong.
    ///
    /// `DefunctConnection` is the daemon saying it dropped us, after a Wi-Fi change, a daemon
    /// restart or a spell in the background, and the only cure for it is a new browser.
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
