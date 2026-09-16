import CoreGraphics
import Darwin
import Foundation

/// Sets supported physical displays to zero brightness without changing the pixels being
/// composited. ScreenCaptureKit therefore keeps seeing and streaming the desktop while a person
/// in front of the Mac sees a dark panel.
///
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
                return "None of the connected displays lets macOS change its brightness."
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

    @discardableResult
    func enable() throws -> Int {
        guard saved.isEmpty else { return saved.count }
        guard let getBrightness, let setBrightness else { throw Failure.unavailable }

        let displays = Self.activeDisplays()
        var originals: [SavedBrightness] = []
        for displayID in displays {
            var value: Float = 0
            guard getBrightness(displayID, &value) == 0 else { continue }
            originals.append(SavedBrightness(displayID: displayID, value: value))
        }
        guard !originals.isEmpty else { throw Failure.noSupportedDisplay }

        // Persist before making the first panel dark. If the process dies after the hardware
        // write, the next launch still knows the value it owes back.
        persist(originals)

        var changed: [SavedBrightness] = []
        for original in originals where setBrightness(original.displayID, 0) == 0 {
            changed.append(original)
        }
        guard !changed.isEmpty else {
            UserDefaults.standard.removeObject(forKey: Self.recoveryKey)
            throw Failure.noSupportedDisplay
        }

        saved = changed
        persist(changed)
        return changed.count
    }

    func restore() {
        guard let setBrightness else { return }
        let values = saved.isEmpty ? Self.persistedValues() : saved
        guard !values.isEmpty else { return }

        var failed: [SavedBrightness] = []
        for item in values where setBrightness(item.displayID, item.value) != 0 {
            failed.append(item)
        }
        saved = []
        if failed.isEmpty {
            UserDefaults.standard.removeObject(forKey: Self.recoveryKey)
        } else {
            persist(failed)
        }
    }

    private func restoreAbandonedSession() {
        guard Self.persistedValues().isEmpty == false else { return }
        restore()
    }

    private func persist(_ values: [SavedBrightness]) {
        guard let data = try? JSONEncoder().encode(values) else { return }
        UserDefaults.standard.set(data, forKey: Self.recoveryKey)
    }

    private static func persistedValues() -> [SavedBrightness] {
        guard let data = UserDefaults.standard.data(forKey: recoveryKey) else { return [] }
        return (try? JSONDecoder().decode([SavedBrightness].self, from: data)) ?? []
    }

    private static func activeDisplays() -> [CGDirectDisplayID] {
        var count: UInt32 = 0
        guard CGGetActiveDisplayList(0, nil, &count) == .success, count > 0 else { return [] }
        var displays = [CGDirectDisplayID](repeating: 0, count: Int(count))
        guard CGGetActiveDisplayList(count, &displays, &count) == .success else { return [] }
        return Array(displays.prefix(Int(count)))
    }
}
