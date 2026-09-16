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
