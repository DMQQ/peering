import PeeringKit
import RemoteCore
import SwiftUI
import UIKit

/// Shared by the source list and the settings panel. One shape at two sizes: every number is a ratio of `size` (the shipped 42-point value over 42), so the picker's 60-point grid keeps the same corner and padding.
struct ApplicationIcon: View {
    let data: Data?
    let fallback: String

    var size: CGFloat = 42

    private var corner: CGFloat { size * (11.0 / 42.0) }

    var body: some View {
        Group {
            if let data, let image = UIImage(data: data) {
                Image(uiImage: image)
                    .resizable()
                    .scaledToFit()
            } else {
                Image(systemName: fallback)
                    .font(.system(size: size * (20.0 / 42.0), weight: .medium))
                    .foregroundStyle(.secondary)
                    .padding(size * (8.0 / 42.0))
            }
        }
        .frame(width: size, height: size)
        .background(
            .white.opacity(0.07),
            in: RoundedRectangle(cornerRadius: corner, style: .continuous)
        )
        .clipShape(RoundedRectangle(cornerRadius: corner, style: .continuous))
    }
}
