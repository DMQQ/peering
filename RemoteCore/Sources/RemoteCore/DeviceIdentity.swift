import Foundation

/// Not a secret and not derived from hardware: it is a name, and the pin is what authenticates.
public struct DeviceIdentity: Sendable, Equatable {
    public let id: String
    public let name: String

    private static let idKey = "Peering.deviceID"
    private static let nameKey = "Peering.deviceName"

    public init(id: String, name: String) {
        self.id = id
        self.name = name
    }

    /// `defaultName` is supplied by the caller because the fallback differs by platform.
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

    public func saveName(_ newName: String, to defaults: UserDefaults = .standard) {
        defaults.set(newName, forKey: Self.nameKey)
    }
}
