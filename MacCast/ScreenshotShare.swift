import UIKit

/// Captures the current remote screen (including the stream and its controls) and opens the
/// system share sheet. This intentionally stays on-device: no screenshot bytes are sent to the
/// Mac or stored in the app.
enum ScreenshotShare {
    @MainActor
    static func present() {
        guard let window = UIApplication.shared.connectedScenes
            .compactMap({ $0 as? UIWindowScene })
            .flatMap(\.windows)
            .first(where: \.isKeyWindow)
        else { return }

        let renderer = UIGraphicsImageRenderer(bounds: window.bounds)
        let image = renderer.image { _ in
            window.drawHierarchy(in: window.bounds, afterScreenUpdates: true)
        }
        let controller = UIActivityViewController(activityItems: [image], applicationActivities: nil)
        var presenter = window.rootViewController
        while let presented = presenter?.presentedViewController { presenter = presented }
        presenter?.present(controller, animated: true)
    }
}
