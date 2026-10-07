import SwiftUI

/// Portrait works; this says once that side-on gives the picture the whole display. The rotate button exists because an app cannot read Rotation Lock: a refused rotation request is the only signal.
struct LandscapeHint: View {
    var rotationRefused: Bool
    var onRotate: () -> Void
    var onDismiss: () -> Void

    var body: some View {
        VStack(spacing: 14) {
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
        .glassSurface(in: RoundedRectangle(cornerRadius: 24, style: .continuous))
        .contentShape(Rectangle())
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
