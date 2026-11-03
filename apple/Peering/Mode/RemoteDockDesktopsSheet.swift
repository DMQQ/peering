import RemoteCore
import SwiftUI
import UIKit

/// The Mac's desktops as pictures, drawn like the screen view's desktop tiles, for the trackpad. A tap moves the Mac to that desktop and changes nothing about what is captured, since the trackpad shows no picture.
struct RemoteDockDesktopsSheet: View {
    @Environment(SessionModel.self) private var model
    @Environment(\.dismiss) private var dismiss

    private static let columns = [GridItem(.adaptive(minimum: 140), spacing: 12, alignment: .top)]

    var body: some View {
        let displays = model.catalog?.spaceInfo?.displays ?? []
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                TabScreenHeader(String(localized: "Desktops"))
                ForEach(displays) { display in
                    VStack(alignment: .leading, spacing: 10) {
                        if displays.count > 1 {
                            SectionLabel(String(localized: "Display \((displays.firstIndex(of: display) ?? 0) + 1)"))
                        }
                        LazyVGrid(columns: Self.columns, alignment: .leading, spacing: 14) {
                            ForEach(1...max(display.count, 1), id: \.self) { index in
                                tile(display, index: index)
                            }
                        }
                    }
                }
            }
            .padding(.horizontal, 20)
            .padding(.top, 22)
            .padding(.bottom, 24)
        }
        .background(ColorPalette.backdrop.ignoresSafeArea())
        .onAppear { model.send(.refreshSpacePreviews) }
    }

    private func tile(_ display: SpaceDisplay, index: Int) -> some View {
        let isCurrent = display.current == index
        let shape = RoundedRectangle(cornerRadius: 10, style: .continuous)
        return Button {
            model.send(.switchToSpace(display: display.displayID, index: index))
            dismiss()
        } label: {
            VStack(alignment: .leading, spacing: 6) {
                ColorPalette.surface
                    .overlay { preview(display, index: index) }
                    .aspectRatio(16.0 / 10.0, contentMode: .fit)
                    .clipShape(shape)
                    .overlay {
                        shape.strokeBorder(
                            ColorPalette.ink.opacity(isCurrent ? 0.6 : 0.18),
                            lineWidth: isCurrent ? 1.5 : 1
                        )
                    }
                Text(isCurrent ? String(localized: "Desktop \(index) · here") : String(localized: "Desktop \(index)"))
                    .font(.caption.weight(isCurrent ? .semibold : .regular))
                    .foregroundStyle(isCurrent ? ColorPalette.ink : Color.secondary)
                    .lineLimit(1)
            }
        }
        .buttonStyle(RailButtonStyle(scale: 0.95, haptic: true))
    }

    @ViewBuilder
    private func preview(_ display: SpaceDisplay, index: Int) -> some View {
        if let data = display.preview(for: index)?.jpegData, let image = UIImage(data: data) {
            Image(uiImage: image)
                .resizable()
                .aspectRatio(contentMode: .fill)
        } else {
            // A desktop not visited since the Mac's Peering started has no picture yet.
            Image(systemName: "rectangle.dashed")
                .font(.system(size: 20, weight: .medium))
                .foregroundStyle(.tertiary)
        }
    }
}
