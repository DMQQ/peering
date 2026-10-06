import CoreGraphics
import Darwin
import Foundation

/// Display brightness is deliberately changed once, not enforced continuously. The Mac's
/// physical brightness-up key remains an escape hatch and Privacy Mode never fights it.
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

    var dimmedDisplayIDs: Set<CGDirectDisplayID> { Set(saved.map(\.displayID)) }

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

    /// Only built-in and Apple displays: on a third-party monitor Get refuses but Set returns success, so the write blinks the panel black.
    private static func acceptsBrightnessWrite(_ displayID: CGDirectDisplayID) -> Bool {
        CGDisplayIsBuiltin(displayID) != 0 || CGDisplayVendorNumber(displayID) == appleVendorID
    }

    static func activeDisplayIDs() -> [CGDirectDisplayID] {
        var count: UInt32 = 0
        guard CGGetActiveDisplayList(0, nil, &count) == .success, count > 0 else { return [] }
        var displays = [CGDirectDisplayID](repeating: 0, count: Int(count))
        guard CGGetActiveDisplayList(count, &displays, &count) == .success else { return [] }
        return Array(displays.prefix(Int(count)))
    }
}
