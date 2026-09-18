@preconcurrency import AVFoundation
import SwiftUI
import UIKit

/// Camera surface used only during pairing, and it hands back whatever the QR code said.
///
/// Two different codes are read through it, and neither is a credential: the Mac's pairing
/// panel shows the six-digit SAS value the user can also type by hand, and the same panel
/// shows the Mac's device ID for pairing across networks. Which one was scanned is decided by
/// ``PairingPayload``, not here — this type only knows how to read a QR code, and a view that
/// wants one kind of code has to say what it does with the other.
struct PairingCodeScanner: UIViewControllerRepresentable {
    let onCode: (String) -> Void

    func makeCoordinator() -> Coordinator { Coordinator(onCode: onCode) }

    func makeUIViewController(context: Context) -> ScannerViewController {
        let controller = ScannerViewController()
        controller.metadataDelegate = context.coordinator
        return controller
    }

    func updateUIViewController(_ controller: ScannerViewController, context: Context) {}

    final class Coordinator: NSObject, AVCaptureMetadataOutputObjectsDelegate {
        private let onCode: (String) -> Void
        private var delivered = false

        init(onCode: @escaping (String) -> Void) { self.onCode = onCode }

        func metadataOutput(
            _ output: AVCaptureMetadataOutput,
            didOutput metadataObjects: [AVMetadataObject],
            from connection: AVCaptureConnection
        ) {
            guard !delivered,
                  let readable = metadataObjects.first as? AVMetadataMachineReadableCodeObject,
                  let value = readable.stringValue
            else { return }
            delivered = true
            onCode(value)
        }
    }
}

final class ScannerViewController: UIViewController {
    weak var metadataDelegate: AVCaptureMetadataOutputObjectsDelegate?
    private let session = AVCaptureSession()
    private var previewLayer: AVCaptureVideoPreviewLayer?

    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = .black
        configureCamera()
    }

    override func viewDidLayoutSubviews() {
        super.viewDidLayoutSubviews()
        previewLayer?.frame = view.bounds
    }

    override func viewWillAppear(_ animated: Bool) {
        super.viewWillAppear(animated)
        if !session.isRunning {
            DispatchQueue.global(qos: .userInitiated).async { [session] in session.startRunning() }
        }
    }

    override func viewDidDisappear(_ animated: Bool) {
        super.viewDidDisappear(animated)
        if session.isRunning {
            DispatchQueue.global(qos: .utility).async { [session] in session.stopRunning() }
        }
    }

    private func configureCamera() {
        guard let camera = AVCaptureDevice.default(for: .video),
              let input = try? AVCaptureDeviceInput(device: camera),
              session.canAddInput(input)
        else {
            showUnavailableMessage()
            return
        }
        session.addInput(input)

        let metadata = AVCaptureMetadataOutput()
        guard session.canAddOutput(metadata) else {
            showUnavailableMessage()
            return
        }
        session.addOutput(metadata)
        metadata.setMetadataObjectsDelegate(metadataDelegate, queue: .main)
        metadata.metadataObjectTypes = [.qr]

        let preview = AVCaptureVideoPreviewLayer(session: session)
        preview.videoGravity = .resizeAspectFill
        view.layer.insertSublayer(preview, at: 0)
        previewLayer = preview
    }

    private func showUnavailableMessage() {
        let label = UILabel()
        label.text = "Camera unavailable\nEnter the six-digit code instead."
        label.numberOfLines = 0
        label.textAlignment = .center
        label.textColor = .secondaryLabel
        label.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(label)
        NSLayoutConstraint.activate([
            label.centerXAnchor.constraint(equalTo: view.centerXAnchor),
            label.centerYAnchor.constraint(equalTo: view.centerYAnchor),
            label.leadingAnchor.constraint(greaterThanOrEqualTo: view.leadingAnchor, constant: 24),
        ])
    }
}
