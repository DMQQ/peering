import CoreTransferable
import os
import PhotosUI
import SwiftUI
import UniformTypeIdentifiers

private let photoLog = Logger(subsystem: "pl.dmq.peering", category: "file-browser")

/// A picked photo or video as a file in the temporary folder. Imported as a file and not as `Data`, since a video held in memory is a termination.
private struct PickedMedia: Transferable {
    let url: URL

    static var transferRepresentation: some TransferRepresentation {
        FileRepresentation(importedContentType: .item) { received in
            let folder = FileManager.default.temporaryDirectory
                .appendingPathComponent("PeeringPhotoUploads", isDirectory: true)
                .appendingPathComponent(UUID().uuidString, isDirectory: true)
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            let copy = folder.appendingPathComponent(received.file.lastPathComponent)
            try FileManager.default.copyItem(at: received.file, to: copy)
            return PickedMedia(url: copy)
        }
    }
}

private struct PhotoUploadPicker: ViewModifier {
    @Binding var isPresented: Bool
    let deliver: ([URL]) -> Void

    @State private var selection: [PhotosPickerItem] = []

    func body(content: Content) -> some View {
        content
            .photosPicker(isPresented: $isPresented, selection: $selection, matching: .any(of: [.images, .videos]))
            .onChange(of: selection) { _, items in
                guard !items.isEmpty else { return }
                selection = []
                Task {
                    var urls: [URL] = []
                    for item in items {
                        do {
                            if let media = try await item.loadTransferable(type: PickedMedia.self) { urls.append(media.url) }
                        } catch {
                            photoLog.error("could not read a picked photo: \(error.localizedDescription, privacy: .public)")
                        }
                    }
                    if !urls.isEmpty { deliver(urls) }
                }
            }
    }
}

extension View {
    /// Presents the photo library; what is picked is handed over as temporary files, like the Files importer's result.
    func photoUploadPicker(isPresented: Binding<Bool>, deliver: @escaping ([URL]) -> Void) -> some View {
        modifier(PhotoUploadPicker(isPresented: isPresented, deliver: deliver))
    }
}
