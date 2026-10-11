import SwiftUI

/// Shown once a phone has typed the digits by hand: unlike a scanned QR code, that proves nothing to the Mac, so its user is the one who decides. It replaces the code and the QR rather than sitting under them, because by now both have been used and the decision is the only thing left to show.
/// One row when the window is wide, so the question and its two answers are read together and the panel does not push the live picture off the screen; stacked when it is narrow.
struct PairingApprovalCard: View {
    let clientName: String
    let resolve: (Bool) -> Void

    var body: some View {
        ViewThatFits(in: .horizontal) {
            HStack(spacing: 16) {
                glyph
                question(alignment: .leading)
                Spacer(minLength: 12)
                buttons.frame(width: 250)
            }
            VStack(spacing: 16) {
                HStack(spacing: 14) {
                    glyph
                    question(alignment: .leading)
                }
                buttons
            }
        }
    }

    private var glyph: some View {
        Image(systemName: "iphone.gen3")
            .font(.system(size: 20, weight: .light))
            .foregroundStyle(HostPalette.ink)
            .frame(width: 46, height: 46)
            .background(HostPalette.raised, in: Circle())
            .overlay { Circle().strokeBorder(HostPalette.litEdge, lineWidth: 1) }
    }

    private func question(alignment: HorizontalAlignment) -> some View {
        VStack(alignment: alignment, spacing: 3) {
            Text(String(localized: "Pair \(clientName)?"))
                .font(HostDisplayFont.display(19))
                .tracking(-0.4)
                .lineLimit(2)
                .fixedSize(horizontal: false, vertical: true)
            Text("It entered the code shown on this Mac. Only approve if that was you.")
                .font(.caption)
                .foregroundStyle(HostPalette.muted)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private var buttons: some View {
        HStack(spacing: 10) {
            Button { resolve(false) } label: {
                Text("Decline")
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(HostPalette.ink)
                    .frame(maxWidth: .infinity, minHeight: 40)
                    .background(HostPalette.raised, in: Capsule())
                    .overlay { Capsule().strokeBorder(HostPalette.hairline, lineWidth: 1) }
                    .contentShape(Capsule())
            }
            .keyboardShortcut(.cancelAction)

            Button { resolve(true) } label: {
                Text("Approve")
                    .font(.subheadline.weight(.bold))
                    .foregroundStyle(.black)
                    .frame(maxWidth: .infinity, minHeight: 40)
                    .background(HostPalette.ink, in: Capsule())
                    .contentShape(Capsule())
            }
            .keyboardShortcut(.defaultAction)
        }
        .buttonStyle(.plain)
    }
}
