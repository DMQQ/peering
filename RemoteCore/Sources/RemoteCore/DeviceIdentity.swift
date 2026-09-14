import Foundation

/// A device's persistent, human-recognisable identity, as advertised over Bonjour.
///
/// The ID is generated once and kept in `UserDefaults`, so the device is recognised as the
/// same one across launches, network changes, and DHCP reassignments. Bonjour only carries
/// it — its real job is to be stored by the peer next to the pin, so each side can tell
/// "my Mac" from "some other Mac that happens to be on this café's Wi-Fi".
///
/// It is deliberately *not* a secret and deliberately not derived from hardware. It is a
/// name, and the pin is what actually authenticates.
public struct DeviceIdentity: Sendable, Equatable {
    public let id: String
    public let name: String

    private static let idKey = "MacCast.deviceID"
    private static let nameKey = "MacCast.deviceName"

    public init(id: String, name: String) {
        self.id = id
        self.name = name
    }

    /// Loads the stored identity, minting a fresh ID on first run.
    ///
    /// `defaultName` is supplied by the caller rather than derived here: the sensible
    /// fallback differs by platform (`ProcessInfo.hostName` on macOS, `UIDevice.name` on
    /// iOS), and neither is available to a module that compiles for both.
    public static func loadOrCreate(
        defaultName: String,
        from defaults: UserDefaults = .standard
    ) -> DeviceIdentity {
        let id: String
        if let stored = defaults.string(forKey: idKey), !stored.isEmpty {
            id = stored
        } else {
            id = UUID().uuidString
            defaults.set(id, forKey: idKey)
        }

        let storedName = defaults.string(forKey: nameKey)
        let name = (storedName?.isEmpty == false ? storedName : nil) ?? defaultName
        return DeviceIdentity(id: id, name: name)
    }

    /// Persists a user-chosen name.
    public func saveName(_ newName: String, to defaults: UserDefaults = .standard) {
        defaults.set(newName, forKey: Self.nameKey)
    }
}
