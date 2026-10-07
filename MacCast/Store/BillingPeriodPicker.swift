import MacCastKit
import StoreKit
import SwiftUI

struct BillingPeriodPicker: View {
    @Binding var period: BillingPeriod
    var saving: Int?

    private static let savingLift: CGFloat = 19

    var body: some View {
        HStack(spacing: 4) {
            ForEach(BillingPeriod.allCases) { option in
                Button {
                    period = option
                } label: {
                    Text(option == .monthly ? "Monthly" : "Yearly")
                        .font(.subheadline.weight(.medium))
                        .foregroundStyle(period == option ? ColorPalette.ink : ColorPalette.ink.opacity(0.55))
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 9)
                        .background {
                            Capsule()
                                .fill(ColorPalette.accent.opacity(period == option ? 0.22 : 0))
                        }
                        .contentShape(Capsule())
                        .overlay(alignment: .top) {
                            if option == .yearly, let saving {
                                Text("Save \(saving)%")
                                    .font(.system(size: 10, weight: .bold))
                                    .tracking(0.4)
                                    .foregroundStyle(ColorPalette.accent)
                                    .padding(.horizontal, 7)
                                    .padding(.vertical, 2)
                                    .background(ColorPalette.accent.opacity(0.18), in: Capsule())
                                    .offset(y: -Self.savingLift)
                                    .accessibilityHidden(true)
                            }
                        }
                }
                .buttonStyle(.plain)
                .accessibilityAddTraits(period == option ? [.isSelected] : [])
                .accessibilityValue(accessibilityValue(for: option))
            }
        }
        .padding(3)
        .background(ColorPalette.ink.opacity(0.05), in: Capsule())
        .padding(.top, Self.savingLift)
        .animation(Motion.tap, value: period)
    }

    private func accessibilityValue(for option: BillingPeriod) -> String {
        guard option == .yearly, let saving else { return "" }
        return String(localized: "Save \(saving) percent")
    }
}

#Preview {
    PaywallView(onDismiss: {})
        .environment(StoreManager())
        .preferredColorScheme(.dark)
}
