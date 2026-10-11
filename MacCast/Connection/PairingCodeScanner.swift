@preconcurrency import AVFoundation
import SwiftUI
import UIKit

struct PairingCodeScanner: UIViewControllerRepresentable {
    /// QR code the app itself draws. This used to be a one-shot callback: the flag that stopped
    /// it firing twice was set *before* the payload was looked at, so the first wrong code
    /// (somebody's Wi-Fi code, a screenshot, the Mac's own ID) ended the scanner for the life of
    /// the sheet. The camera kept running, the picture kept moving, and nothing it saw was ever
    /// reported again.
    let onCode: (String) -> Bool

    func makeCoordinator() -> Coordinator { Coordinator(onCode: onCode) }

    func makeUIViewController(context: Context) -> ScannerViewController {
        let controller = ScannerViewController()
        controller.metadataDelegate = context.coordinator
        return controller
    }

    func updateUIViewController(_ controller: ScannerViewController, context: Context) {}

    final class Coordinator: NSObject, AVCaptureMetadataOutputObjectsDelegate {
        private let onCode: (String) -> Bool
        private var delivered = false

        init(onCode: @escaping (String) -> Bool) { self.onCode = onCode }

        func metadataOutput(
            _ output: AVCaptureMetadataOutput,
            didOutput metadataObjects: [AVMetadataObject],
            from connection: AVCaptureConnection
        ) {
            guard !delivered,
                  let readable = metadataObjects.first as? AVMetadataMachineReadableCodeObject,
                  let value = readable.stringValue
            else { return }
            if onCode(value) { delivered = true }
        }
    }
}

final class ScannerViewController: UIViewController {
    weak var metadataDelegate: AVCaptureMetadataOutputObjectsDelegate?
    private let session = AVCaptureSession()
    private var previewLayer: AVCaptureVideoPreviewLayer?
    private var isConfigured = false
    private var showsMessage = false

    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = .black
    }

    override func viewDidLayoutSubviews() {
        super.viewDidLayoutSubviews()
        previewLayer?.frame = view.bounds
    }

    /// Everything waits for the sheet to be on screen with a size, and for the camera to be allowed: configured while the sheet was still sliding up, or before the first permission answer, the preview came up black and stayed that way until the sheet was reopened.
    override func viewDidAppear(_ animated: Bool) {
        super.viewDidAppear(animated)
        switch AVCaptureDevice.authorizationStatus(for: .video) {
        case .authorized:
            startCamera()
        case .notDetermined:
            AVCaptureDevice.requestAccess(for: .video) { [weak self] granted in
                DispatchQueue.main.async { granted ? self?.startCamera() : self?.showUnavailableMessage() }
            }
        default:
            showUnavailableMessage()
        }
    }

    override func viewDidDisappear(_ animated: Bool) {
        super.viewDidDisappear(animated)
        if session.isRunning {
            DispatchQueue.global(qos: .utility).async { [session] in session.stopRunning() }
        }
    }

    private func startCamera() {
        if !isConfigured { configureCamera() }
        guard isConfigured, !session.isRunning else { return }
        previewLayer?.frame = view.bounds
        DispatchQueue.global(qos: .userInitiated).async { [session] in session.startRunning() }
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
        preview.frame = view.bounds
        view.layer.insertSublayer(preview, at: 0)
        previewLayer = preview
        isConfigured = true
    }

    /// Two reasons, and the difference matters to whoever is holding the phone. A device or a
    /// simulator without one is a fact about the hardware; a camera this app has been refused is
    /// a switch somebody can go and turn on, and "Camera unavailable" sends them looking for a
    /// problem with their phone. The typed code is the way past either, so it is named here
    /// rather than left to be discovered.
    private func showUnavailableMessage() {
        guard !showsMessage else { return }
        showsMessage = true
        let refused = AVCaptureDevice.authorizationStatus(for: .video) == .denied
        let label = UILabel()
        label.text = refused
            ? String(localized: "Peering is not allowed to use the camera.\nAllow Camera in Settings, or enter the six-digit code instead.")
            : String(localized: "Camera unavailable\nEnter the six-digit code instead.")
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

        guard refused, let url = URL(string: UIApplication.openSettingsURLString) else { return }
        var configuration = UIButton.Configuration.bordered()
        configuration.title = String(localized: "Open Settings")
        let button = UIButton(configuration: configuration, primaryAction: UIAction { _ in
            UIApplication.shared.open(url)
        })
        button.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(button)
        NSLayoutConstraint.activate([
            button.centerXAnchor.constraint(equalTo: view.centerXAnchor),
            button.topAnchor.constraint(equalTo: label.bottomAnchor, constant: 18),
        ])
    }
}
