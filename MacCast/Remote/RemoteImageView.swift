import ImageIO
import RemoteCore
import SwiftUI
import UIKit
import WebKit

struct RemoteImageView: View {
    let data: Data
    let kind: RemoteFileKind
    let identity: String

    @State private var image: UIImage?

    var body: some View {
        Group {
            if kind == .svg {
                SVGImageView(data: data)
            } else if let image {
                ZoomingImageView(image: image)
            } else {
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

    nonisolated private static let maximumAnimatedFrames = 64
    nonisolated private static let maximumAnimatedPixels = 64_000_000
}

private struct ZoomingImageView: UIViewRepresentable {
    let image: UIImage

    func makeUIView(context: Context) -> FittingScrollView {
        let scroll = FittingScrollView()
        scroll.backgroundColor = .clear
        scroll.delegate = context.coordinator
        scroll.minimumZoomScale = 1
        scroll.maximumZoomScale = 8
        scroll.showsVerticalScrollIndicator = false
        scroll.showsHorizontalScrollIndicator = false
        scroll.contentInsetAdjustmentBehavior = .never

        let view = UIImageView(image: image)
        view.contentMode = .scaleAspectFit
        scroll.addSubview(view)
        scroll.imageView = view
        context.coordinator.imageView = view

        let doubleTap = UITapGestureRecognizer(target: context.coordinator, action: #selector(Coordinator.doubleTapped(_:)))
        doubleTap.numberOfTapsRequired = 2
        scroll.addGestureRecognizer(doubleTap)
        return scroll
    }

    func updateUIView(_ scroll: FittingScrollView, context: Context) {
        guard let view = context.coordinator.imageView else { return }
        if view.image !== image { view.image = image }
    }

    func makeCoordinator() -> Coordinator { Coordinator() }

    final class Coordinator: NSObject, UIScrollViewDelegate {
        weak var imageView: UIImageView?

        func viewForZooming(in scrollView: UIScrollView) -> UIView? { imageView }

        @objc func doubleTapped(_ gesture: UITapGestureRecognizer) {
            guard let scroll = gesture.view as? UIScrollView, let imageView else { return }
            if scroll.zoomScale > 1 {
                scroll.setZoomScale(1, animated: true)
                return
            }
            let target: CGFloat = 3
            let point = gesture.location(in: imageView)
            let size = CGSize(width: scroll.bounds.width / target, height: scroll.bounds.height / target)
            scroll.zoom(to: CGRect(x: point.x - size.width / 2, y: point.y - size.height / 2, width: size.width, height: size.height), animated: true)
        }
    }
}

/// **Sized by hand, not by constraints.** A zoomable view whose content is laid out by Auto Layout has a content size UIKit never learns, and the zoom then anchors at the top left instead of the pinch. At rest the picture fills the viewport (aspect-fit does the letterboxing); zoomed, the frame is UIKit's to scale, so only the rest state is set here.
private final class FittingScrollView: UIScrollView {
    weak var imageView: UIImageView?
    private var laidOutSize = CGSize.zero

    override func layoutSubviews() {
        super.layoutSubviews()
        guard let imageView, bounds.size != laidOutSize, zoomScale == 1 else { return }
        laidOutSize = bounds.size
        imageView.frame = CGRect(origin: .zero, size: bounds.size)
        contentSize = bounds.size
    }
}

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
            baseURL: URL(string: "about:blank")!
        )
    }

    func makeCoordinator() -> Coordinator { Coordinator() }

    final class Coordinator: NSObject, WKNavigationDelegate {
        var loaded: Data?

        func webView(
            _ webView: WKWebView,
            decidePolicyFor navigationAction: WKNavigationAction,
            decisionHandler: @escaping @MainActor (WKNavigationActionPolicy) -> Void
        ) {
            decisionHandler(navigationAction.navigationType == .other ? .allow : .cancel)
        }
    }
}
