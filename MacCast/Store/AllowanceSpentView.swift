import MacCastKit
import StoreKit
import SwiftUI

/// **The one ending that has nothing on screen to explain it.** Every other way a session stops
/// says so somewhere: the Mac locked, the network went, the user tapped End. This one is a socket
/// closing. The relay ends a session the moment its window is spent, and it has nowhere to say
/// why: everything past the session token is a TLS connection it cannot write into, and the
/// signalling socket is a different connection that may already be closed. What the user sees is
/// their Mac vanishing, then a reconnect that is refused, and nothing anywhere about money.
struct AllowanceSpentView: View {
    let plan: RelayPlan
    let onDismiss: () -> Void

    @Environment(StoreManager.self) private var store

    /// Presented from inside here rather than by closing this and setting the session's
    /// ``SessionModel/paywallReason``, which is how every other door opens it. Two sheets on one
    /// view cannot cross in the same update (the dismissal and the presentation race), and a
    /// nested sheet is the shape that does not.
    @State private var showsPlans = false

    var body: some View {
        ZStack {
            ColorPalette.backdrop.ignoresSafeArea()
            TopGlow()

            VStack(alignment: .leading, spacing: 16) {
                Image(systemName: "clock.badge.exclamationmark")
                    .font(.system(size: 46, weight: .light))
                    .foregroundStyle(ColorPalette.ink)
                    .frame(height: 56)

                VStack(alignment: .leading, spacing: 8) {
                    Text(title)
                        .font(DisplayFont.display(28))
                        .tracking(-1)

                    Text(detail)
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }

                WelcomePrimaryButton(title: String(localized: "See the plans")) { showsPlans = true }
                    .padding(.top, 4)

                Button("Not now") { onDismiss() }
                    .font(.footnote.weight(.medium))
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity)
                    .buttonStyle(.plain)
            }
            .padding(.horizontal, 18)
            .padding(.vertical, 24)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .sheet(isPresented: $showsPlans) {
            PaywallView(reason: .upgrade, onDismiss: { showsPlans = false })
                .environment(store)
                .preferredColorScheme(.dark)
        }
    }

    private var title: String {
        switch plan {
        case .free: return String(localized: "Your free relay time is used up")
        case .relay, .pro:
            // Unreachable as the app is wired: paid plans are unlimited and never cut for quota.
            // True rather than blank, like the paywall's own unreachable branches.
            return String(localized: "The relay stopped the session")
        }
    }

    private var detail: String {
        let stillFree = String(localized: "Your own network is unlimited on every plan, and still works.")
        switch plan {
        case .free:
            return String(localized: "That session went over the relay, and free's \(plan.allowanceSpelling) a day are spent. Another relayed session is refused until the allowance comes back. \(stillFree)")
        case .relay, .pro:
            return String(localized: "Your plan has no daily limit, so the relay counting this one means it read the device as free. Try again, and tell us if it keeps happening. \(stillFree)")
        }
    }
}

// MARK: - Legal
