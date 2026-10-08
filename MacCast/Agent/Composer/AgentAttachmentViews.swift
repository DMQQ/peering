import ImageIO
import SwiftUI
import UniformTypeIdentifiers

struct Attachment: Identifiable, Equatable {
    let id = UUID()
    let name: String
    let path: String
    var thumbnail: UIImage?
    var failure: String?

    var symbol: String { AgentFileGlyph.symbol(for: name) }

    /// A small preview read off the picked file, so an image shows as itself rather than as a path.
    static func thumbnail(of url: URL) -> UIImage? {
        guard UTType(filenameExtension: url.pathExtension)?.conforms(to: .image) == true else { return nil }
        let scoped = url.startAccessingSecurityScopedResource()
        defer { if scoped { url.stopAccessingSecurityScopedResource() } }
        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil),
              let image = CGImageSourceCreateThumbnailAtIndex(source, 0, [
                  kCGImageSourceCreateThumbnailFromImageAlways: true,
                  kCGImageSourceCreateThumbnailWithTransform: true,
                  kCGImageSourceThumbnailMaxPixelSize: 160,
              ] as CFDictionary)
        else { return nil }
        return UIImage(cgImage: image)
    }
}

enum AgentFileGlyph {
    static func symbol(for name: String) -> String {
        let type = UTType(filenameExtension: (name as NSString).pathExtension)
        if type?.conforms(to: .image) == true { return "photo" }
        if type?.conforms(to: .pdf) == true { return "doc.richtext" }
        if type?.conforms(to: .sourceCode) == true { return "chevron.left.forwardslash.chevron.right" }
        if type?.conforms(to: .archive) == true { return "doc.zipper" }
        return "doc"
    }
}

struct AgentFileChip: View {
    let name: String
    var symbol: String?
    var thumbnail: UIImage?
    var isUploading = false
    var failure: String?
    var remove: (() -> Void)?

    var body: some View {
        HStack(spacing: 8) {
            tile
            VStack(alignment: .leading, spacing: 0) {
                Text(verbatim: name)
                    .font(.system(size: 12.5, weight: .medium))
                    .foregroundStyle(failure == nil ? ColorPalette.ink : ColorPalette.danger)
                    .lineLimit(1)
                    .truncationMode(.middle)
                if let failure {
                    Text(failure)
                        .font(.system(size: 10.5))
                        .foregroundStyle(ColorPalette.danger.opacity(0.8))
                        .lineLimit(1)
                } else if isUploading {
                    Text("Sending to your Mac")
                        .font(.system(size: 10.5))
                        .foregroundStyle(.white.opacity(0.5))
                }
            }
            .frame(maxWidth: 150, alignment: .leading)
            if let remove {
                Button(action: remove) {
                    Image(systemName: "xmark")
                        .font(.system(size: 9, weight: .bold))
                        .foregroundStyle(.white.opacity(0.7))
                        .frame(width: 22, height: 22)
                        .background(.white.opacity(0.12), in: Circle())
                        .contentShape(Circle())
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Remove")
            }
        }
        .padding(5)
        .padding(.trailing, remove == nil ? 6 : 2)
        .overlay {
            RoundedRectangle(cornerRadius: 15, style: .continuous)
                .strokeBorder(failure == nil ? .white.opacity(0.16) : ColorPalette.danger.opacity(0.4))
        }
        .opacity(isUploading ? 0.75 : 1)
    }

    private var tile: some View {
        ZStack {
            if let thumbnail {
                Image(uiImage: thumbnail)
                    .resizable()
                    .scaledToFill()
            } else {
                Image(systemName: failure == nil ? (symbol ?? "doc") : "exclamationmark.triangle.fill")
                    .font(.system(size: 14, weight: .medium))
                    .foregroundStyle(failure == nil ? .white.opacity(0.85) : ColorPalette.danger)
            }
            if isUploading {
                Color.black.opacity(0.35)
                ProgressView().controlSize(.small).tint(.white)
            }
        }
        .frame(width: 36, height: 36)
        .background(.white.opacity(0.1))
        .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
    }
}

struct AgentAttachmentTray: View {
    let items: [Attachment]
    let uploading: Attachment?
    let remove: (UUID) -> Void

    var body: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 8) {
                ForEach(items) { item in
                    AgentFileChip(
                        name: item.name,
                        symbol: item.symbol,
                        thumbnail: item.thumbnail,
                        failure: item.failure,
                        remove: { remove(item.id) }
                    )
                    .transition(.scale(scale: 0.6).combined(with: .opacity))
                }
                if let uploading {
                    AgentFileChip(name: uploading.name, symbol: uploading.symbol, thumbnail: uploading.thumbnail, isUploading: true)
                        .transition(.scale(scale: 0.6).combined(with: .opacity))
                }
            }
            .padding(.horizontal, 14)
            .padding(.top, 4)
            .padding(.bottom, 2)
        }
        .scrollBounceBehavior(.basedOnSize)
        .animation(.spring(response: 0.42, dampingFraction: 0.64), value: items.count)
        .animation(.spring(response: 0.42, dampingFraction: 0.64), value: uploading?.id)
    }
}
