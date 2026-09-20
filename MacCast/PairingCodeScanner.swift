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
    /// Hands over what the code said, and answers whether it was any use.
    ///
    /// **The answer is why this is not `(String) -> Void`.** The scanner reads whatever QR code
    /// is in front of the camera, and the screens that use it are looking for one particular
    /// kind: the pairing prompt wants six digits and refuses a Mac's device ID, which is also a
    /// QR code the app itself draws. This used to be a one-shot callback: the flag that stopped
    /// it firing twice was set *before* the payload was looked at, so the first wrong code
    /// (somebody's Wi-Fi code, a screenshot, the Mac's own ID) ended the scanner for the life of
    /// the sheet. The camera kept running, the picture kept moving, and nothing it saw was ever
    /// reported again.
    ///
    /// Returning `false` leaves the scanner armed; returning `true` retires it. A caller that
    /// cannot refuse anything just returns `true`.
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
            // Set only once the code has been taken. A code that was refused leaves this false,
            // and the next one to come into frame gets the same chance the first one had.
            if onCode(value) { delivered = true }
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

    /// Says that there is no camera to scan with, and why.
    ///
    /// Two reasons, and the difference matters to whoever is holding the phone. A device or a
    /// simulator without one is a fact about the hardware; a camera this app has been refused is
    /// a switch somebody can go and turn on, and "Camera unavailable" sends them looking for a
    /// problem with their phone. The typed code is the way past either, so it is named here
    /// rather than left to be discovered.
    private func showUnavailableMessage() {
        let refused = AVCaptureDevice.authorizationStatus(for: .video) == .denied
        let label = UILabel()
        label.text = refused
            ? "Peering is not allowed to use the camera.\nAllow Camera in Settings, or enter the six-digit code instead."
            : "Camera unavailable\nEnter the six-digit code instead."
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
        configuration.title = "Open Settings"
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
