import UIKit

/// Captures the current remote screen (including the stream and its controls) and opens the
/// system share sheet. This intentionally stays on-device: no screenshot bytes are sent to the
/// Mac or stored in the app.
enum ScreenshotShare {
    /// The capture, under a name that says what it is.
    ///
    /// **A file rather than a bare `UIImage`, and that is the whole of what the sheet says.** The
    /// sheet draws its first item as the header, and an image with no name draws a thumbnail with
    /// nothing under it: a camera glyph had been pressed and a wordless sheet appeared. A file
    /// carries its name into the header, into AirDrop, and into what Mail attaches.
    /// **`nonisolated`, because the sheet asks this from its own queue.** The module's default
    /// isolation makes everything main-actor, and this protocol's callbacks are not: the share
    /// sheet resolves its items off the main thread, and an isolated conformance traps there
    /// (`SIGTRAP` in `checkExpectedExecutor`, from the system reading the file it was handed).
    /// Nothing here needs the main actor anyway: two values, held and returned.
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

        /// What Mail puts in the subject line, and what Messages starts the message with. The
        /// filename already says the same thing, so this is the line rather than the fact.
        func activityViewController(
            _ controller: UIActivityViewController,
            subjectForActivityType type: UIActivity.ActivityType?
        ) -> String {
            subject
        }

        /// Says the file is an image, which is what offers "Save Image" beside the filename. A URL
        /// on its own is an anonymous attachment and the activity is not offered.
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

        // **The sheet is a popover on iPad, and a popover with nothing to point at is a crash.**
        // This app ships to both device families and this is the only share sheet in it, so there
        // was nothing else to carry the anchor. The centre of the screen is not where the button
        // is, but a sheet with no arrow is a sheet, and a sheet that throws is not a sheet.
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

    /// The name the sheet shows, and the file it keeps.
    ///
    /// Written beside the app rather than into it, so nothing accumulates in the app's own storage
    /// and the file goes when the system clears its temporary directory. Every capture clears the
    /// last one first: they are all named after the same Mac, and a folder of them is not what
    /// anybody came for.
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

    /// The Mac's name, which is what a screenshot of it is a screenshot of. A slash would make the
    /// name a path and a colon hides it in Finder, so both become dashes.
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
