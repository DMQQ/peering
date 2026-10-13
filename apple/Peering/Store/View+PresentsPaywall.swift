import PeeringKit
import StoreKit
import SwiftUI

extension View {
    /// **Attached in more than one place, and it has to be, which is the whole reason this is a
    /// modifier rather than a `.sheet` written out where it is needed.** A sheet can only be
    /// presented by a view that is not already presenting one. This app puts locks inside sheets:
    /// the terminal is a sheet, and its deck, its quick commands and the file browser all carry one.
    /// A paywall presented from the root while the terminal is up is a presentation UIKit refuses
    /// in silence, and the failure looks exactly like the app ignoring the tap.
    func presentsPaywall(_ model: SessionModel) -> some View {
        sheet(isPresented: Binding(
            get: { model.paywallReason != nil },
            set: { if !$0 { model.paywallReason = nil } }
        )) {
            PaywallView(reason: model.paywallReason ?? .upgrade) { model.paywallReason = nil }
                .environment(model.storeManager)
                .preferredColorScheme(.dark)
                .presentationDetents([.fraction(0.6)])
                .presentationSizing(.form)
        }
    }
}
