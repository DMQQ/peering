import ImageIO
import RemoteCore
import SwiftUI
import UIKit
import WebKit

/// A picture that came off another machine, drawn at the size of the space it is given.
///
/// Two renderers behind one view, because the two kinds are not the same problem. A raster image is
/// bytes that `UIImage` decodes, and everything it needs is in the file. An SVG is a *document* —
/// XML that a layout engine has to interpret — and UIKit has no decoder for one, so it is handed to
/// the only engine on the system that does.
///
/// Both are zoomable, and that is not a nicety: a screenshot read on a phone at fit-to-screen is
/// unreadable, and the alternative to pinching is downloading the file to look at it somewhere
/// else, which is a much longer way round to the same thing.
struct RemoteImageView: View {
    let data: Data
    let kind: RemoteFileKind
    /// What to load. The file's path, so that opening a second picture in the same panel replaces
    /// the first rather than being mistaken for a redraw of it.
    let identity: String

    /// The decoded picture, or nothing until it is ready.
    ///
    /// Held rather than decoded in `body`, because a GIF is decoded by reading every frame and that
    /// is not something to do on every layout pass.
    @State private var image: UIImage?

    var body: some View {
        Group {
            if kind == .svg {
                SVGImageView(data: data)
            } else if let image {
                ZoomingImageView(image: image)
            } else {
                // Reached twice: while the decode is in flight, and if it failed. The second is
                // rare enough to share a state with the first — the Mac decided this was a picture
                // before sending it, so a failure here means the file lied to both ends.
                VStack(spacing: 10) {
                    ProgressView().controlSize(.small)
                    Text("Opening…")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .task(id: identity) {
            guard kind != .svg else { return }
            // Off the main actor, because decoding a picture means touching every pixel of it: at
            // the eight megabytes this can be sent, doing that on the actor that is drawing the
            // screen is not a slow preview, it is a spinner that stops turning until it is over.
            let decoded = await Task.detached(priority: .userInitiated) {
                Self.decode(data)
            }.value
            image = decoded
        }
    }

    /// The bytes as a picture, animated if they are a GIF that can afford to be.
    ///
    /// `nonisolated` because it is called from a detached task — see the comment on the call.
    /// Nothing in it reads or writes anything this view holds; it takes bytes and gives back a
    /// picture, which is exactly the shape of work that has no business being on an actor.
    ///
    /// **The frame budget is a memory decision, not a taste one.** `UIImage.animatedImage` holds
    /// every frame decoded at once, so a large animated GIF multiplies its own size by its frame
    /// count: a thousand-pixel GIF of a hundred frames is a quarter of a gigabyte resident, which
    /// on a phone is not a slow preview, it is a termination. Past the budget the first frame is
    /// drawn instead, which is a still picture rather than a wrong one.
    nonisolated private static func decode(_ data: Data) -> UIImage? {
        guard let source = CGImageSourceCreateWithData(data as CFData, nil) else { return nil }
        let count = CGImageSourceGetCount(source)
        guard count > 1, count <= maximumAnimatedFrames else { return UIImage(data: data) }

        var frames: [UIImage] = []
        var pixels = 0
        var duration: Double = 0
        for index in 0..<count {
            guard let frame = CGImageSourceCreateImageAtIndex(source, index, nil) else { continue }
            pixels += frame.width * frame.height
            guard pixels <= maximumAnimatedPixels else { return UIImage(data: data) }
            frames.append(UIImage(cgImage: frame))
            duration += frameDuration(source, index)
        }
        guard !frames.isEmpty else { return UIImage(data: data) }
        return UIImage.animatedImage(with: frames, duration: duration)
    }

    /// How long one GIF frame is held.
    ///
    /// The unclamped value where there is one, because that is the one a browser honours and the
    /// clamped one has already had the interesting answers rounded away. The floor is the rule
    /// every GIF viewer has converged on: a delay of less than 20 ms means "as fast as you can",
    /// and honouring it literally is a slideshow nobody can see.
    nonisolated private static func frameDuration(_ source: CGImageSource, _ index: Int) -> Double {
        let properties = CGImageSourceCopyPropertiesAtIndex(source, index, nil) as? [CFString: Any]
        let gif = properties?[kCGImagePropertyGIFDictionary] as? [CFString: Any]
        let delay = (gif?[kCGImagePropertyGIFUnclampedDelayTime] as? Double)
            ?? (gif?[kCGImagePropertyGIFDelayTime] as? Double)
            ?? 0.1
        return delay < 0.02 ? 0.1 : delay
    }

    /// The most frames a GIF will be animated with. Past this the first frame stands in for all of
    /// them, which is a still picture rather than a wrong one.
    nonisolated private static let maximumAnimatedFrames = 64
    /// Sixty-four megapixels across all frames, which is a quarter of a gigabyte in memory at four
    /// bytes a pixel. Chosen as the point past which a phone starts deciding for us.
    nonisolated private static let maximumAnimatedPixels = 64_000_000
}

/// A raster image, drawn to fit and pinched to zoom.
///
/// A scroll view rather than SwiftUI's `scaleEffect`, because zooming a picture is panning as well
/// as scaling — once it is bigger than the screen there is somewhere to be, and a gesture that only
/// scales leaves the rest of the picture off the edge with no way to reach it.
private struct ZoomingImageView: UIViewRepresentable {
    let image: UIImage

    func makeUIView(context: Context) -> UIScrollView {
        let scroll = UIScrollView()
        scroll.backgroundColor = .clear
        scroll.delegate = context.coordinator
        scroll.minimumZoomScale = 1
        scroll.maximumZoomScale = 8
        scroll.showsVerticalScrollIndicator = false
        scroll.showsHorizontalScrollIndicator = false

        let view = UIImageView(image: image)
        view.contentMode = .scaleAspectFit
        view.clipsToBounds = true
        view.translatesAutoresizingMaskIntoConstraints = false
        scroll.addSubview(view)
        // Pinned to the *frame* guide rather than the content guide: at rest the picture is exactly
        // the size of the viewport and the scroll view has nothing to scroll, which is what makes
        // the zoom scale mean what it says. Constraints rather than a frame because the viewport is
        // not known when this is built, and UIKit re-applies them when it is.
        NSLayoutConstraint.activate([
            view.leadingAnchor.constraint(equalTo: scroll.frameLayoutGuide.leadingAnchor),
            view.trailingAnchor.constraint(equalTo: scroll.frameLayoutGuide.trailingAnchor),
            view.topAnchor.constraint(equalTo: scroll.frameLayoutGuide.topAnchor),
            view.bottomAnchor.constraint(equalTo: scroll.frameLayoutGuide.bottomAnchor),
        ])
        context.coordinator.imageView = view
        return scroll
    }

    func updateUIView(_ scroll: UIScrollView, context: Context) {
        guard let view = context.coordinator.imageView else { return }
        if view.image !== image { view.image = image }
    }

    func makeCoordinator() -> Coordinator { Coordinator() }

    final class Coordinator: NSObject, UIScrollViewDelegate {
        weak var imageView: UIImageView?
        func viewForZooming(in scrollView: UIScrollView) -> UIView? { imageView }
    }
}

/// An SVG, drawn by the only thing on the system that can draw one.
///
/// **A web view because there is no other option, and locked down because of what one is.** An SVG
/// is an XML document, an XML document can carry a `<script>`, and this one came off somebody
/// else's machine — a server the user happens to have an account on, or their own Mac. Rendering it
/// must never mean running it, so JavaScript is off, nothing is persisted, and the view refuses to
/// go anywhere.
private struct SVGImageView: UIViewRepresentable {
    let data: Data

    func makeUIView(context: Context) -> WKWebView {
        let configuration = WKWebViewConfiguration()
        configuration.defaultWebpagePreferences.allowsContentJavaScript = false
        // No store at all: an SVG is not a site, and nothing it does should outlive the panel.
        configuration.websiteDataStore = .nonPersistent()

        let view = WKWebView(frame: .zero, configuration: configuration)
        view.navigationDelegate = context.coordinator
        view.isOpaque = false
        view.backgroundColor = .clear
        view.scrollView.backgroundColor = .clear
        view.scrollView.minimumZoomScale = 1
        view.scrollView.maximumZoomScale = 8
        return view
    }

    func updateUIView(_ view: WKWebView, context: Context) {
        // Loaded once per file. `updateUIView` runs for reasons that have nothing to do with the
        // picture, and reloading on one of those would throw away a zoom the user had just set.
        guard context.coordinator.loaded != data else { return }
        context.coordinator.loaded = data
        view.load(
            data,
            mimeType: "image/svg+xml",
            characterEncodingName: "utf-8",
            // An empty base, so a relative reference inside the document resolves to nothing rather
            // than to somewhere on the machine that sent it.
            baseURL: URL(string: "about:blank")!
        )
    }

    func makeCoordinator() -> Coordinator { Coordinator() }

    /// Refuses every navigation that is not the document itself.
    ///
    /// JavaScript being off already means no script can send the view anywhere, so what is left is
    /// a link the user could tap. A picture is not a page, and a tap on one leaving the panel for a
    /// web page would be a surprise at best.
    final class Coordinator: NSObject, WKNavigationDelegate {
        var loaded: Data?

        func webView(
            _ webView: WKWebView,
            decidePolicyFor navigationAction: WKNavigationAction,
            decisionHandler: @escaping (WKNavigationActionPolicy) -> Void
        ) {
            decisionHandler(navigationAction.navigationType == .other ? .allow : .cancel)
        }
    }
}
