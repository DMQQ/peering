import StoreKit
import SwiftUI

/// Shown when the relay's free allowance is exhausted for the period.
struct PaywallView: View {
    @Environment(StoreManager.self) private var store
    var onDismiss: () -> Void

    var body: some View {
        ZStack {
            ColorPalette.backdrop.ignoresSafeArea()
            light

            ScrollView {
                VStack(alignment: .leading, spacing: 26) {
                    header
                    if store.products.isEmpty {
                        loadingPlaceholder
                    } else {
                        productList
                    }
                    footer
                }
                .padding(.horizontal, 18)
                .padding(.vertical, 24)
                .containerRelativeFrame(.vertical, alignment: .center)
            }

            SkipButton(action: onDismiss)
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topTrailing)
        }
        .task { await store.start() }
    }

    // MARK: - Sections

    private var header: some View {
        VStack(alignment: .leading, spacing: 14) {
            Image(systemName: "network")
                .font(.system(size: 46, weight: .light))
                .foregroundStyle(ColorPalette.ink)
                .frame(height: 56)

            VStack(alignment: .leading, spacing: 8) {
                Text("Keep going from anywhere")
                    .font(.system(size: 28, weight: .bold))
                    .tracking(-0.5)

                Text("Your free relay time for this month is used up. Upgrade to connect from anywhere without limits.")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    private var productList: some View {
        VStack(spacing: 10) {
            ForEach(store.products, id: \.id) { product in
                ProductCard(product: product)
            }

            if let error = store.purchaseError {
                Text(error)
                    .font(.caption)
                    .foregroundStyle(.red)
                    .multilineTextAlignment(.leading)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal, 4)
            }
        }
    }

    private var loadingPlaceholder: some View {
        HStack {
            Spacer()
            ProgressView()
            Spacer()
        }
        .padding(.vertical, 32)
    }

    private var footer: some View {
        VStack(spacing: 8) {
            Button {
                Task { await store.restore() }
            } label: {
                Text("Restore purchases")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity)
            }
            .buttonStyle(.plain)

            Text("Relay carries your encrypted session — it cannot read what it forwards.")
                .font(.caption2)
                .foregroundStyle(.tertiary)
                .multilineTextAlignment(.center)
                .frame(maxWidth: .infinity)
        }
    }

    private var light: some View {
        RadialGradient(
            colors: [.white.opacity(0.07), .clear],
            center: .top,
            startRadius: 0,
            endRadius: 460
        )
        .ignoresSafeArea()
        .allowsHitTesting(false)
    }
}

// MARK: - Product card

private struct ProductCard: View {
    @Environment(StoreManager.self) private var store
    let product: Product

    var isSubscription: Bool { product.type == .autoRenewable }

    var body: some View {
        Button {
            Task { await store.purchase(product) }
        } label: {
            HStack(spacing: 14) {
                VStack(alignment: .leading, spacing: 3) {
                    Text(product.displayName)
                        .font(.subheadline.weight(.semibold))
                        .foregroundStyle(.primary)
                    Text(product.description)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }

                Spacer(minLength: 8)

                if store.isPurchasing {
                    ProgressView()
                        .tint(ColorPalette.ink)
                } else {
                    VStack(alignment: .trailing, spacing: 2) {
                        Text(product.displayPrice)
                            .font(.subheadline.weight(.semibold))
                            .foregroundStyle(ColorPalette.ink)
                        if isSubscription {
                            Text("/ month")
                                .font(.caption2)
                                .foregroundStyle(.secondary)
                        }
                    }
                }
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 14)
            .background(.white.opacity(0.06), in: RoundedRectangle(cornerRadius: 14))
        }
        .buttonStyle(.plain)
        .disabled(store.isPurchasing)
    }
}

#Preview {
    PaywallView(onDismiss: {})
        .environment(StoreManager())
        .preferredColorScheme(.dark)
}
