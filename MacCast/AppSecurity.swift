import LocalAuthentication
import SwiftUI

/// The one gate protecting every way into the app: a row tap, widget, URL, or Shortcut.
/// Putting authentication around individual connect buttons would leave the other entrances
/// unprotected and would also interrupt an automatic reconnect after a brief network drop.
enum DeviceAuthentication {
    static var isAvailable: Bool {
        let context = LAContext()
        var error: NSError?
        return context.canEvaluatePolicy(.deviceOwnerAuthenticationWithBiometrics, error: &error)
    }

    static func authenticate(reason: String) async -> Bool {
        let context = LAContext()
        context.localizedCancelTitle = "Cancel"
        var error: NSError?
        guard context.canEvaluatePolicy(.deviceOwnerAuthenticationWithBiometrics, error: &error) else {
            return false
        }
        do {
            return try await context.evaluatePolicy(
                .deviceOwnerAuthenticationWithBiometrics,
                localizedReason: reason
            )
        } catch {
            return false
        }
    }

    // MARK: - A single server's own lock

    /// What this device's biometry is, read from a throwaway context.
    ///
    /// `biometryType` is only filled in *after* a policy has been evaluated, which is the sort of
    /// detail that ends up shipping a menu labelled "Biometrics" to somebody who has never seen
    /// that word. Asking a context that is about to be thrown away is what gets it answered
    /// without asking the user for a face.
    private static var biometryType: LABiometryType {
        let context = LAContext()
        var error: NSError?
        guard context.canEvaluatePolicy(.deviceOwnerAuthentication, error: &error) else { return .none }
        return context.biometryType
    }

    /// What it is called, so a picker can say "Face ID" rather than "biometrics".
    static var biometryName: String {
        switch biometryType {
        case .faceID: return "Face ID"
        case .touchID: return "Touch ID"
        case .opticID: return "Optic ID"
        default: return "Biometrics"
        }
    }

    /// The glyph that goes with it — a Touch ID device showing a face reads as the wrong screen.
    static var biometrySymbol: String {
        switch biometryType {
        case .touchID: return "touchid"
        case .opticID: return "opticid"
        default: return "faceid"
        }
    }

    /// Whether this device can answer a per-server lock at all, so the option is not offered where
    /// it cannot be honoured.
    static var canLockServers: Bool {
        let context = LAContext()
        var error: NSError?
        return context.canEvaluatePolicy(.deviceOwnerAuthentication, error: &error)
    }

    /// The gate a server's own lock asks for.
    ///
    /// `.deviceOwnerAuthentication` rather than the biometric-only policy above, and the difference
    /// is deliberate. That one protects a switch the user turns on for the whole app and can turn
    /// off again; this one is *stored on a server*, and a server whose only way in was a face the
    /// phone no longer recognises — because the user re-enrolled, or is wearing a mask in a dark
    /// room — would be a server they can no longer open from here at all. The device passcode is
    /// the fallback Apple provides for exactly this, and it is still something only the owner
    /// knows.
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

/// Leaves a running session alive while hiding all of its controls and picture. Locking the
/// app must not look like a disconnect to the Mac, and a network reconnect that happens while
/// Face ID is up should be allowed to finish behind the gate.
struct SecuredRootView<Content: View>: View {
    @Environment(\.scenePhase) private var scenePhase
    @AppStorage(PreferenceKey.requireBiometricUnlock) private var isProtectionEnabled = false

    @State private var isUnlocked = false
    @State private var isAuthenticating = false

    private let content: Content

    init(@ViewBuilder content: () -> Content) {
        self.content = content()
    }

    var body: some View {
        ZStack {
            content
                .privacySensitive(isProtectionEnabled)
                .allowsHitTesting(!isProtectionEnabled || isUnlocked)

            if isProtectionEnabled && !isUnlocked {
                ColorPalette.backdrop.ignoresSafeArea()

                VStack(spacing: 18) {
                    Image(systemName: "faceid")
                        .font(.system(size: 48, weight: .light))
                    Text("Peering is locked")
                        .font(.title2.weight(.bold))
                    Button("Unlock with Face ID") { unlock() }
                        .buttonStyle(.borderedProminent)
                        .tint(ColorPalette.ink)
                        .foregroundStyle(ColorPalette.onInk)
                        .disabled(isAuthenticating)
                }
            }
        }
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
                reason: "Unlock Peering and access your paired Macs."
            )
            isUnlocked = accepted
            isAuthenticating = false
        }
    }
}
