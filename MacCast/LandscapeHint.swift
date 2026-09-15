import SwiftUI

/// The card that tells a new session's user to turn the phone.
///
/// Portrait is not a failure — the dock and the joystick are built for it — but a Mac's screen is
/// wide, and side-on is where the picture gets the whole display and both thumbs reach the
/// controls at once. Most people work that out on their own within a few seconds. This spends
/// three of them saying so, once, at the moment the picture first appears.
///
/// The rotate button exists for the case that actually needs help, and it is a narrower case than
/// it looks. An app cannot read iOS's Rotation Lock, so a user who has it on will turn the phone,
/// watch nothing happen, and have no way to tell whether the app is broken or the phone is
/// locked. Asking iOS to rotate either happens or comes back as an error, and that error is the
/// only signal available — which is why the button, and not just the instruction, is here.
struct LandscapeHint: View {
    /// Whether a rotation has already been refused, which means Rotation Lock is on.
    var rotationRefused: Bool
    var onRotate: () -> Void
    var onDismiss: () -> Void

    var body: some View {
        VStack(spacing: 14) {
            // The device itself, on its side. The host picker draws a Mac and a phone rather than
            // using a glyph for them, and this is the same idea at the one size that fits a card.
            Image(systemName: "iphone.gen3.landscape")
                .font(.system(size: 36, weight: .light))
                .foregroundStyle(ColorPalette.ink)

            VStack(spacing: 5) {
                Text(rotationRefused ? "Rotation is locked" : "Turn your phone")
                    .font(.headline)

                Text(
                    rotationRefused
                        ? "Turn off Rotation Lock in Control Centre, then turn the phone on its side."
                        : "The desktop fits better on its side."
                )
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            }
            .multilineTextAlignment(.center)

            if !rotationRefused {
                Button("Rotate", action: onRotate)
                    .font(.subheadline.weight(.semibold))
                    .buttonStyle(.borderedProminent)
                    .tint(ColorPalette.ink)
                    .foregroundStyle(.black)
            }
        }
        .padding(22)
        .frame(maxWidth: 290)
        .glassEffect(.regular, in: RoundedRectangle(cornerRadius: 24, style: .continuous))
        .contentShape(Rectangle())
        // The whole card dismisses, not just a button on it. It is three seconds of the user's
        // time and it has already said what it has to say; making them find a target to be rid of
        // it is a worse interruption than the one it exists to apologise for.
        .onTapGesture { onDismiss() }
        .accessibilityElement(children: .combine)
        .accessibilityHint("Double tap to dismiss")
    }
}

#Preview {
    ZStack {
        Color.black.ignoresSafeArea()
        LandscapeHint(rotationRefused: false, onRotate: {}, onDismiss: {})
    }
    .preferredColorScheme(.dark)
}
