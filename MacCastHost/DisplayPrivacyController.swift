import CoreGraphics
import Darwin
import Foundation

/// Sets supported physical displays to zero brightness without changing the pixels being
/// composited. ScreenCaptureKit therefore keeps seeing and streaming the desktop while a person
/// in front of the Mac sees a dark panel.
///
/// Display brightness is deliberately changed once, not enforced continuously. The Mac's
/// physical brightness-up key remains an escape hatch and Privacy Mode never fights it.
///
/// This half is only for displays a brightness write holds on. Everything it leaves alone is
/// covered instead by ``DisplayPrivacyCurtain``.
final class DisplayPrivacyController {
    enum Failure: LocalizedError {
        case unavailable
        case noSupportedDisplay

        var errorDescription: String? {
            switch self {
            case .unavailable:
                return "This version of macOS does not expose display brightness control."
            case .noSupportedDisplay:
                return "No display on this Mac takes a brightness change from macOS."
            }
        }
    }

    private struct SavedBrightness: Codable {
        let displayID: CGDirectDisplayID
        let value: Float
    }

    private typealias GetBrightness = @convention(c) (
        CGDirectDisplayID, UnsafeMutablePointer<Float>
    ) -> Int32
    private typealias SetBrightness = @convention(c) (CGDirectDisplayID, Float) -> Int32

    private static let recoveryKey = "Peering.privacyMode.savedBrightness"
    private static let frameworkPath =
        "/System/Library/PrivateFrameworks/DisplayServices.framework/DisplayServices"

    /// Apple's display vendor ID. Every display macOS will set a brightness on belongs to it,
    /// which is what makes it the right hedge. See ``acceptsBrightnessWrite(_:)``.
    private static let appleVendorID: UInt32 = 0x610

    private let framework: UnsafeMutableRawPointer?
    private let getBrightness: GetBrightness?
    private let setBrightness: SetBrightness?
    private var saved: [SavedBrightness] = []

    init() {
        let framework = dlopen(Self.frameworkPath, RTLD_LAZY | RTLD_LOCAL)
        self.framework = framework
        if let framework,
           let get = dlsym(framework, "DisplayServicesGetBrightness"),
           let set = dlsym(framework, "DisplayServicesSetBrightness") {
            getBrightness = unsafeBitCast(get, to: GetBrightness.self)
            setBrightness = unsafeBitCast(set, to: SetBrightness.self)
        } else {
            getBrightness = nil
            setBrightness = nil
        }

        // A hard crash cannot run cleanup. Keep the original levels on disk and repair them on
        // the next launch before accepting another session.
        restoreAbandonedSession()
    }

    deinit {
        restore()
        if let framework { dlclose(framework) }
    }

    /// The displays this Mac holds at zero brightness, now that the call has returned.
    var dimmedDisplayIDs: Set<CGDirectDisplayID> { Set(saved.map(\.displayID)) }

    /// Dims every display that takes a brightness write and does not already hold one.
    ///
    /// Incremental on purpose: called again when a display is attached mid-session, it picks up
    /// the display that arrived and leaves the ones it has already dimmed alone.
    @discardableResult
    func enable() throws -> Set<CGDirectDisplayID> {
        guard let getBrightness, let setBrightness else { throw Failure.unavailable }

        let alreadyDimmed = dimmedDisplayIDs
        var candidates: [SavedBrightness] = []
        for displayID in Self.activeDisplayIDs() where !alreadyDimmed.contains(displayID) {
            guard Self.acceptsBrightnessWrite(displayID) else { continue }
            var value: Float = 0
            guard getBrightness(displayID, &value) == 0 else { continue }
            candidates.append(SavedBrightness(displayID: displayID, value: value))
        }
        guard !candidates.isEmpty || !alreadyDimmed.isEmpty else { throw Failure.noSupportedDisplay }

        // Persist before the first panel goes dark. If the process dies after the hardware write,
        // the next launch still knows every value it owes back.
        persist(saved + candidates)

        var dimmed = alreadyDimmed
        for candidate in candidates where setBrightness(candidate.displayID, 0) == 0 {
            dimmed.insert(candidate.displayID)
        }
        // A writer that refused is a display that never changed, and one left in the record would
        // be written back on the way out: a brightness change on a panel nobody dimmed.
        saved = (saved + candidates).filter { dimmed.contains($0.displayID) }
        persist(saved)
        guard !saved.isEmpty else { throw Failure.noSupportedDisplay }
        return dimmed
    }

    func restore() {
        guard let setBrightness else { return }
        let values = saved.isEmpty ? Self.persistedValues() : saved
        guard !values.isEmpty else { return }

        var failed: [SavedBrightness] = []
        for item in values where setBrightness(item.displayID, item.value) != 0 {
            failed.append(item)
        }
        saved = failed
        persist(failed)
    }

    private func restoreAbandonedSession() {
        guard Self.persistedValues().isEmpty == false else { return }
        restore()
    }

    private func persist(_ values: [SavedBrightness]) {
        guard !values.isEmpty else {
            UserDefaults.standard.removeObject(forKey: Self.recoveryKey)
            return
        }
        guard let data = try? JSONEncoder().encode(values) else { return }
        UserDefaults.standard.set(data, forKey: Self.recoveryKey)
    }

    private static func persistedValues() -> [SavedBrightness] {
        guard let data = UserDefaults.standard.data(forKey: recoveryKey) else { return [] }
        return (try? JSONDecoder().decode([SavedBrightness].self, from: data)) ?? []
    }

    /// Whether a brightness write to this display is one that holds.
    ///
    /// The built-in panel and Apple's own displays, and nothing else, because the two calls do
    /// not agree on what they support: on a third-party monitor `DisplayServicesGetBrightness`
    /// refuses with an error while `DisplayServicesSetBrightness` for the same display returns
    /// success, so a write is passed on to a monitor that will not keep it. What that looks like
    /// is the panel blinking black and coming straight back, which is worse than not trying: a
    /// flash pulls the eye to the screen at the exact moment Privacy Mode exists to take attention
    /// away from it. Such a display is covered by ``DisplayPrivacyCurtain`` instead.
    private static func acceptsBrightnessWrite(_ displayID: CGDirectDisplayID) -> Bool {
        CGDisplayIsBuiltin(displayID) != 0 || CGDisplayVendorNumber(displayID) == appleVendorID
    }

    /// Every display the window server is compositing, in its own order.
    static func activeDisplayIDs() -> [CGDirectDisplayID] {
        var count: UInt32 = 0
        guard CGGetActiveDisplayList(0, nil, &count) == .success, count > 0 else { return [] }
        var displays = [CGDirectDisplayID](repeating: 0, count: Int(count))
        guard CGGetActiveDisplayList(count, &displays, &count) == .success else { return [] }
        return Array(displays.prefix(Int(count)))
    }
}
