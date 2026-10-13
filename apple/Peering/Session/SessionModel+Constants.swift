import Foundation

extension SessionModel {
    static let standardConnectTimeout: TimeInterval = 10

    /// Short, because it is the one dial whose address may be wrong.
    static let rememberedPathTimeout: TimeInterval = 3

    /// A ceiling on the phone: each open Mac costs a control connection, a keepalive and a sleep assertion.
    static let sessionCeiling = 4

    static let manualAddressKey = "Peering.manualAddress"

    static let manualPortKey = "Peering.manualPort"

    static let lastHostNameKey = "Peering.lastHostName"
    static let lastHostIDKey = "Peering.lastHostID"

    static let resumeKey = "Peering.resumeWhenReachable"
}
