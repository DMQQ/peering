import PeeringKit
import MessageUI
import RemoteCore
import SSHCore
import SwiftUI
import UIKit

extension View {
    /// The radius is passed in because the previews differ in size: a real widget's corner is about a sixth of its height.
    func widgetPreviewSurface(radius: CGFloat) -> some View {
        background {
            RoundedRectangle(cornerRadius: radius, style: .continuous)
                .fill(
                    LinearGradient(
                        colors: [.white.opacity(0.13), .white.opacity(0.07)],
                        startPoint: .topLeading,
                        endPoint: .bottomTrailing
                    )
                )
                .overlay {
                    RoundedRectangle(cornerRadius: radius, style: .continuous)
                        .strokeBorder(.white.opacity(0.12))
                }
        }
    }
}

// MARK: - Lock Screen Widget Preview

struct LockScreenWidgetPreview: View {
    var body: some View {
        HStack(spacing: 10) {
            ZStack {
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .fill(Color.white.opacity(0.15))
                    .frame(width: 36, height: 36)
                Image(systemName: "cursorarrow.motionlines")
                    .font(.system(size: 16, weight: .medium))
                    .foregroundStyle(.white)
            }

            VStack(alignment: .leading, spacing: 2) {
                Text("Peering")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(.white)
                HStack(spacing: 6) {
                    Image(systemName: "wifi")
                        .font(.system(size: 9, weight: .semibold))
                    Text("LAN · 0:24")
                        .font(.system(size: 10))
                }
                .foregroundStyle(.white.opacity(0.7))
            }

            Spacer()

            Text("0:24")
                .font(.system(size: 13, weight: .semibold, design: .rounded))
                .monospacedDigit()
                .foregroundStyle(.white)
                .padding(.horizontal, 10)
                .padding(.vertical, 5)
                .background(Color.white.opacity(0.15), in: Capsule())
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
        .background(
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .fill(Color(white: 0.12))
                .overlay {
                    RoundedRectangle(cornerRadius: 16, style: .continuous)
                        .strokeBorder(Color.white.opacity(0.12), lineWidth: 1)
                }
        )
        .padding(.top, 2)
    }
}
