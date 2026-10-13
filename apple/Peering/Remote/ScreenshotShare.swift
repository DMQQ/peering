import UIKit

/// Captures the remote screen and opens the share sheet. Stays on-device: no bytes go to the Mac or the app's storage.
enum ScreenshotShare {
    /// A file rather than a bare `UIImage`: the sheet draws its first item as the header, and an unnamed image gave a wordless sheet. A file carries its name into the header, AirDrop and Mail.
    /// `nonisolated`: the share sheet resolves its items off the main thread, and an isolated conformance traps there (SIGTRAP in `checkExpectedExecutor`).
    private nonisolated final class Item: NSObject, UIActivityItemSource {
        let url: URL
        let subject: String

        init(url: URL, subject: String) {
            self.url = url
            self.subject = subject
        }

        func activityViewControllerPlaceholderItem(_ controller: UIActivityViewController) -> Any {
            url
        }

        func activityViewController(
            _ controller: UIActivityViewController,
            itemForActivityType type: UIActivity.ActivityType?
        ) -> Any? {
            url
        }

        func activityViewController(
            _ controller: UIActivityViewController,
            subjectForActivityType type: UIActivity.ActivityType?
        ) -> String {
            subject
        }

        /// Says the file is an image, which offers "Save Image"; a bare URL is an anonymous attachment.
        func activityViewController(
            _ controller: UIActivityViewController,
            dataTypeIdentifierForActivityType type: UIActivity.ActivityType?
        ) -> String {
            "public.png"
        }
    }

    @MainActor
    static func present(hostName: String?) {
        guard let window = UIApplication.shared.connectedScenes
            .compactMap({ $0 as? UIWindowScene })
            .flatMap(\.windows)
            .first(where: \.isKeyWindow)
        else { return }

        let renderer = UIGraphicsImageRenderer(bounds: window.bounds)
        let image = renderer.image { _ in
            window.drawHierarchy(in: window.bounds, afterScreenUpdates: true)
        }
        guard let url = write(image, hostName: hostName) else { return }

        let controller = UIActivityViewController(
            activityItems: [Item(url: url, subject: String(localized: "Screenshot from \(name(hostName))"))],
            applicationActivities: nil
        )
        var presenter = window.rootViewController
        while let presented = presenter?.presentedViewController { presenter = presented }

        // The sheet is a popover on iPad, and a popover with nothing to point at crashes. The screen centre is not where the button is, but a sheet with no arrow beats a throw.
        if let popover = controller.popoverPresentationController, let view = presenter?.view {
            popover.sourceView = view
            popover.sourceRect = CGRect(
                x: view.bounds.midX,
                y: view.bounds.midY,
                width: 0,
                height: 0
            )
            popover.permittedArrowDirections = []
        }
        presenter?.present(controller, animated: true)
    }

    /// Written beside the app so nothing accumulates in its storage; every capture clears the last, since all are named after the same Mac.
    private static func write(_ image: UIImage, hostName: String?) -> URL? {
        guard let data = image.pngData() else { return nil }
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent(String(localized: "Screenshots"), isDirectory: true)
        try? FileManager.default.removeItem(at: directory)
        guard (try? FileManager.default.createDirectory(
            at: directory,
            withIntermediateDirectories: true
        )) != nil else { return nil }

        let url = directory.appendingPathComponent(String(localized: "\(name(hostName)) \(stamp()).png"))
        guard (try? data.write(to: url)) != nil else { return nil }
        return url
    }

    /// A slash would make the name a path and a colon hides it in Finder, so both become dashes.
    private static func name(_ hostName: String?) -> String {
        let trimmed = hostName?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        let cleaned = trimmed
            .replacingOccurrences(of: "/", with: "-")
            .replacingOccurrences(of: ":", with: "-")
        return cleaned.isEmpty ? "Mac" : cleaned
    }

    private static func stamp() -> String {
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd HH.mm.ss"
        return formatter.string(from: Date())
    }
}
