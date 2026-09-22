import Foundation
import RemoteCore

/// The one source a Mac was last left on, remembered for the next time it is opened.
///
/// **Beside the arrangement, because the two answer the same question.** A connection opens on the
/// first display unless something says otherwise, and the something is either the mosaic the user
/// built on that Mac or the single source they left it on. Both are kept per Mac, both are thinned
/// by the catalogue on the way back in, and both exist so that opening a Mac the user knows puts
/// them back where they were rather than at the app's own idea of what to show first.
///
/// **The one source, rather than a list.** An arrangement is several windows in an order and has
/// ``MosaicArrangementStore`` for it; what is kept here is the single picture that was on screen,
/// and the moment a second source goes into it, it is an arrangement and belongs in that store
/// instead. See ``MosaicChoice``.
public enum ChosenSourceStore {
    private static let key = "Peering.chosenSources"

    /// Every Mac's source, by the Mac's own id.
    ///
    /// One dictionary rather than a key per Mac, for the same reason the arrangements are kept
    /// that way: a key built from an id could collide with anything else in the defaults, and the
    /// ids are not known until a Mac answers.
    private static func sources() -> [String: CaptureSource] {
        guard let data = UserDefaults.standard.data(forKey: key),
              let stored = try? JSONDecoder().decode([String: CaptureSource].self, from: data)
        else { return [:] }
        return stored
    }

    /// What is remembered for one Mac, or nothing when nothing has been chosen there.
    public static func load(hostID: String) -> CaptureSource? {
        sources()[hostID]
    }

    /// Remembers one source against one Mac, or forgets the Mac's when handed nothing.
    public static func save(_ source: CaptureSource?, hostID: String) {
        var stored = sources()
        if let source {
            stored[hostID] = source
        } else {
            // **Forgetting is an assignment of nothing**, the same shape as emptying an
            // arrangement: a separate `forget` call is one more thing a caller can leave out, and
            // what leaving it out leaves behind is a Mac that opens on a source nobody asked for.
            stored.removeValue(forKey: hostID)
        }
        guard let data = try? JSONEncoder().encode(stored) else { return }
        UserDefaults.standard.set(data, forKey: key)
    }
}

public enum ChosenSource {
    /// The remembered source, if this Mac still has it.
    ///
    /// **The catalogue is the filter.** A window id and a process id outlive neither a restart nor
    /// a quit, so what comes back is a source that may or may not still exist, and the only thing
    /// in a session that says which is the catalogue the Mac has just sent. It is applied to a
    /// display as well, which it did not strictly have to be: a display can be unplugged, and one
    /// rule about ids is worth more than a rule per kind kept in step with the catalogue's three
    /// lists.
    public static func restored(_ source: CaptureSource?, into catalog: CaptureCatalog?) -> CaptureSource? {
        guard let source, let catalog else { return nil }
        return catalog.descriptor(for: source) == nil ? nil : source
    }
}
