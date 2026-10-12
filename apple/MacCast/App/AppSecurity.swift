import LocalAuthentication
import MacCastKit
import SwiftUI

/// One gate for every way into the app (row tap, widget, URL, Shortcut): per-button auth would leave other entrances open and interrupt automatic reconnects.
enum DeviceAuthentication {
    /// `.deviceOwnerAuthentication` rather than biometry-only: it falls back to the passcode, so a re-enrolled face or a mask cannot leave a lock with no key.
    static var isAvailable: Bool {
        let context = LAContext()
        var error: NSError?
        return context.canEvaluatePolicy(.deviceOwnerAuthentication, error: &error)
    }

    static func authenticate(reason: String) async -> Bool {
        await unlock(reason: reason)
    }

    // MARK: - A single server's own lock

    /// `biometryType` is only filled in after a policy has been evaluated, so it is read from a throwaway context.
    private static var biometryType: LABiometryType {
        let context = LAContext()
        var error: NSError?
        guard context.canEvaluatePolicy(.deviceOwnerAuthentication, error: &error) else { return .none }
        return context.biometryType
    }

    static var biometryName: String {
        switch biometryType {
        case .faceID: return String(localized: "Face ID")
        case .touchID: return String(localized: "Touch ID")
        case .opticID: return String(localized: "Optic ID")
        default: return String(localized: "Biometrics")
        }
    }

    static var biometrySymbol: String {
        switch biometryType {
        case .touchID: return "touchid"
        case .opticID: return "opticid"
        default: return "faceid"
        }
    }

    static var canLockServers: Bool {
        let context = LAContext()
        var error: NSError?
        return context.canEvaluatePolicy(.deviceOwnerAuthentication, error: &error)
    }

    /// Same policy for the same reason: a lock stored on a server must stay openable when biometry fails.
    static func unlock(reason: String) async -> Bool {
        let context = LAContext()
        context.localizedCancelTitle = "Cancel"
        var error: NSError?
        guard context.canEvaluatePolicy(.deviceOwnerAuthentication, error: &error) else {
            return false
        }
        do {
            return try await context.evaluatePolicy(.deviceOwnerAuthentication, localizedReason: reason)
        } catch {
            return false
        }
    }
}

/// Locking the app must not look like a disconnect to the Mac, and a reconnect during Face ID should finish behind the gate.
struct SecuredRootView<Content: View>: View {
    @Environment(\.scenePhase) private var scenePhase
    @AppStorage(PreferenceKeys.requireBiometricUnlock) private var isProtectionEnabled = false

    @State private var isUnlocked = false
    @State private var isAuthenticating = false

    private var canAuthenticate: Bool { DeviceAuthentication.isAvailable }

    private let content: Content
    private let onLockChange: (Bool) -> Void

    init(onLockChange: @escaping (Bool) -> Void = { _ in }, @ViewBuilder content: () -> Content) {
        self.onLockChange = onLockChange
        self.content = content()
    }

    private var isLocked: Bool { isProtectionEnabled && !isUnlocked }

    var body: some View {
        ZStack {
            content
                .privacySensitive(isProtectionEnabled)
                .allowsHitTesting(!isProtectionEnabled || isUnlocked)

            if isProtectionEnabled && !isUnlocked {
                ColorPalette.backdrop.ignoresSafeArea()

                VStack(spacing: 18) {
                    Image(systemName: canAuthenticate ? DeviceAuthentication.biometrySymbol : "lock.fill")
                        .font(.system(size: 48, weight: .light))
                    Text("Peering is locked")
                        .font(.title2.weight(.bold))

                    if canAuthenticate {
                        Button("Unlock with \(DeviceAuthentication.biometryName)") { unlock() }
                            .buttonStyle(.borderedProminent)
                            .tint(ColorPalette.ink)
                            .foregroundStyle(ColorPalette.onInk)
                            .disabled(isAuthenticating)

                        Text("Your device passcode is accepted too.")
                            .font(.footnote)
                            .foregroundStyle(.secondary)
                    } else {
                        // Escape for a lock that can never open: no passcode and no usable biometry, and the switch that turns it off is behind the lock.
                        Text("This device has no passcode or biometrics set up, so the lock cannot be answered.")
                            .font(.footnote)
                            .foregroundStyle(.secondary)
                            .multilineTextAlignment(.center)
                            .fixedSize(horizontal: false, vertical: true)
                            .padding(.horizontal, 32)

                        Button("Turn the lock off") { isProtectionEnabled = false }
                            .buttonStyle(.bordered)
                            .tint(ColorPalette.ink)
                    }
                }
            }
        }
        .onChange(of: isLocked, initial: true) { _, locked in onLockChange(locked) }
        .task {
            if isProtectionEnabled { unlock() } else { isUnlocked = true }
        }
        .onChange(of: isProtectionEnabled) { _, enabled in
            isUnlocked = !enabled || isUnlocked
        }
        .onChange(of: scenePhase) { _, phase in
            switch phase {
            case .background:
                if isProtectionEnabled { isUnlocked = false }
            case .active:
                if isProtectionEnabled && !isUnlocked { unlock() }
            default:
                break
            }
        }
    }

    private func unlock() {
        guard !isAuthenticating else { return }
        isAuthenticating = true
        Task {
            let accepted = await DeviceAuthentication.authenticate(
                reason: String(localized: "Unlock Peering and access your paired Macs.")
            )
            isUnlocked = accepted
            isAuthenticating = false
        }
    }
}
