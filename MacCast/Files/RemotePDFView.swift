import PDFKit
import SwiftUI

/// A PDF the Mac sent whole, drawn by PDFKit. Rebuilt only when the file changes, so a redraw of the page keeps the reader's place.
struct RemotePDFView: UIViewRepresentable {
    let data: Data
    let identity: String

    func makeUIView(context: Context) -> PDFView {
        let view = PDFView()
        view.backgroundColor = .black
        view.autoScales = true
        view.displayDirection = .vertical
        view.document = PDFDocument(data: data)
        context.coordinator.identity = identity
        return view
    }

    func updateUIView(_ view: PDFView, context: Context) {
        guard context.coordinator.identity != identity else { return }
        context.coordinator.identity = identity
        view.document = PDFDocument(data: data)
    }

    func makeCoordinator() -> Coordinator { Coordinator() }

    final class Coordinator {
        var identity = ""
    }
}
