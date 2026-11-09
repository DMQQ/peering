import SwiftUI

struct ProgressOverlay: View {
    let title: String
    let detail: String?

    var body: some View {
        ZStack {
            Color.black.opacity(0.6).ignoresSafeArea()
            VStack(spacing: 12) {
                ProgressView()
                Text(title).font(.headline)
                if let detail {
                    Text(detail).font(.caption).foregroundStyle(.secondary)
                }
            }
            .padding(24)
            .glassSurface(in: RoundedRectangle(cornerRadius: 20, style: .continuous))
        }
    }
}

/// A quiet wait for the first picture: a spinner and the Mac's name on the black, with no card over it.
struct PicturePlaceholder: View {
    let hostName: String?

    var body: some View {
        VStack(spacing: 10) {
            ProgressView().tint(.white.opacity(0.6))
            if let hostName {
                Text(hostName)
                    .font(.footnote)
                    .foregroundStyle(.white.opacity(0.45))
            }
        }
    }
}
