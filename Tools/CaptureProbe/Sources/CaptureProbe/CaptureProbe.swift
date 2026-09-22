import AppKit
import AVFoundation
import CoreImage
import CoreGraphics
import CoreMedia
import CoreVideo
import Foundation
import RemoteCore

/// Captures the screen, encodes it, writes a playable file, and plays it back.
///
/// This is the phase's exit criterion in executable form: *encoded frames land on disk and
/// play back*. It is not a unit test of the encoder — it runs the host's real
/// `CapturePipeline`, its real `CaptureEngine` and its real `VideoEncoder`, and then asks
/// AVFoundation to decode what came out.
///
/// Four modes, and the two pairs are the point:
///
/// - `--source` (the default) is the real thing: ScreenCaptureKit, TCC, a display or a
///   window. It needs Screen Recording permission, and without it, it fails loudly.
/// - `--synthetic` and `--pipeline` need no permission at all, and between them they cover
///   the two halves of what the default mode does. `--synthetic` calls ``VideoEncoder``
///   directly, so it proves the encoder and nothing above it; `--pipeline` drives the real
///   ``CapturePipeline`` over a generated source, so it proves the pipeline — the frame
///   intake, the keyframe bookkeeping, the statistics, the hand-off of encoded frames —
///   and nothing below it. Neither can prove ScreenCaptureKit itself, which is exactly
///   what the real mode is for.
///
/// Everything it prints is a fact about the machine it ran on. The two failure modes it is
/// built to make loud are the ones that are otherwise silent:
///
/// - Screen Recording not granted. `SCShareableContent` fails with `-3801` if it fails at
///   all; a stream can also start and simply never deliver a frame, which is why the wait
///   loop below gives up and says so rather than reporting success after a quiet three
///   seconds.
/// - The encoder producing something that is not decodable. That shows up as a file that
///   `PlaybackCheck` cannot read, not as an exception at encode time.
@main
struct CaptureProbe {
    struct ProbeError: LocalizedError {
        let message: String
        var errorDescription: String? { message }
    }

    static func main() async {
        do {
            try await run()
        } catch {
            let message = (error as? LocalizedError)?.errorDescription ?? "\(error)"
            FileHandle.standardError.write(Data("\ncapture probe failed: \(message)\n".utf8))
            exit(1)
        }
    }

    // MARK: - Options

    struct Options {
        var seconds: Double = 3
        var output = "/tmp/maccast-capture-probe.mov"
        /// A source's stable id (`display:1`, `window:…`, `application:…`), or a title
        /// fragment. Defaults to the main display.
        var source: String?
        var frameRate = 60
        var listOnly = false
        /// Encode generated frames instead of capturing the screen. See ``SyntheticSource``.
        var synthetic = false
        /// Drive a real `CapturePipeline` over a generated source. See ``runPipeline(_:)``.
        var pipeline = false
        /// Composite several real sources into one canvas. See ``runMosaic(_:)``.
        var mosaic: [String] = []
        /// The canvas to ask for, for checking what a Mac does with one it will not build.
        var canvas = CGSize(width: 1280, height: 720)
        /// Check where the compositor puts two known colours, which needs nothing at all.
        var composeCheck = false
        /// Ask the system for Screen Recording, which puts a prompt on screen.
        var requestAccess = false

        mutating func parse(_ arguments: ArraySlice<String>) throws {
            var iterator = arguments.makeIterator()
            while let argument = iterator.next() {
                switch argument {
                case "--seconds":
                    guard let value = iterator.next(), let seconds = Double(value), seconds > 0 else {
                        throw ProbeError(message: "--seconds needs a positive number")
                    }
                    self.seconds = seconds

                case "--output":
                    guard let value = iterator.next() else {
                        throw ProbeError(message: "--output needs a path")
                    }
                    output = value

                case "--source":
                    guard let value = iterator.next() else {
                        throw ProbeError(message: "--source needs an id or a title fragment")
                    }
                    source = value

                case "--frame-rate":
                    guard let value = iterator.next(), let rate = Int(value), rate > 0 else {
                        throw ProbeError(message: "--frame-rate needs a positive integer")
                    }
                    frameRate = rate

                case "--list":
                    listOnly = true

                case "--synthetic":
                    synthetic = true

                case "--pipeline":
                    pipeline = true

                case "--canvas":
                    guard let value = iterator.next() else {
                        throw ProbeError(message: "--canvas needs WIDTHxHEIGHT")
                    }
                    let parts = value.lowercased().split(separator: "x").compactMap { Double($0) }
                    guard parts.count == 2, parts[0] > 1, parts[1] > 1 else {
                        throw ProbeError(message: "--canvas needs WIDTHxHEIGHT, like 1920x1080")
                    }
                    canvas = CGSize(width: parts[0], height: parts[1])

                case "--mosaic":
                    guard let value = iterator.next() else {
                        throw ProbeError(message: "--mosaic needs a comma-separated list of ids or title fragments")
                    }
                    mosaic = value.split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) }
                    guard !mosaic.isEmpty else {
                        throw ProbeError(message: "--mosaic needs at least one source")
                    }

                case "--compose-check":
                    composeCheck = true

                case "--request-access":
                    requestAccess = true

                case "--help", "-h":
                    print(usage)
                    exit(0)

                default:
                    throw ProbeError(message: "unknown argument “\(argument)”\n\n\(usage)")
                }
            }
        }

        var usage: String {
            """
            usage: CaptureProbe [--seconds N] [--output PATH] [--source ID|TITLE]
                                [--frame-rate N] [--list] [--synthetic] [--pipeline]
                                [--mosaic A,B,…] [--canvas WxH] [--compose-check]
                                [--request-access]

              --seconds N      how long to capture for (default 3)
              --output PATH    where to write the movie (default /tmp/maccast-capture-probe.mov)
              --source ID      a capture source's stable id, or part of its title
              --frame-rate N   frames per second to ask the stream for (default 60)
              --list           print the capture catalogue and exit
              --synthetic      encode generated frames instead of capturing the screen;
                               use this when Screen Recording permission is unavailable
              --pipeline       drive the host's real CapturePipeline over a generated source,
                               so the pipeline itself — not just its encoder — is exercised
                               without Screen Recording permission
              --canvas WxH     the canvas to ask for (default 1280x720), so what a Mac does
                               with one larger than it will build can be seen
              --compose-check  place two known colours through the compositor's own arithmetic
                               and read the canvas back, which needs no Screen Recording
              --mosaic A,B,…   composite the named sources — stable ids or title fragments —
                               into one canvas through the host's MosaicCompositor, and write
                               the result. This is the only check that runs more than one
                               capture at a time, and it needs Screen Recording
              --request-access ask the system for Screen Recording, which puts a prompt on
                               screen and blocks until it is answered
            """
        }
    }

    // MARK: - Entry point

    static func run() async throws {
        var options = Options()
        try options.parse(CommandLine.arguments.dropFirst())

        log("host capture probe")

        // Preflight only reports; it never asks. An app that only ever preflights can sit
        // there permanently denied and show a generic failure. `--request-access` is the one
        // call that puts the system prompt on screen, and it blocks until it is answered —
        // which is why it is opt-in rather than automatic, and why the failure messages
        // below point at it.
        if options.requestAccess, !CGPreflightScreenCaptureAccess() {
            log("requesting Screen Recording — answer the system prompt if it appears")
            let granted = CGRequestScreenCaptureAccess()
            log("request finished: \(granted ? "granted" : "still denied")")
        }

        let granted = CGPreflightScreenCaptureAccess()
        log("screen recording preflight: \(granted ? "granted" : "NOT granted")")

        if options.listOnly {
            try await listSources()
            return
        }

        if options.composeCheck {
            try await runComposeCheck()
        } else if !options.mosaic.isEmpty {
            try await runMosaic(options)
        } else if options.pipeline {
            try await runPipeline(options)
        } else if options.synthetic {
            try await runSynthetic(options)
        } else {
            try await runCapture(options)
        }
    }

    // MARK: - Catalogue

    static func listSources() async throws {
        let resolver = ScreenCaptureSourceResolver()
        let descriptors = try await resolver.catalog().all

        guard !descriptors.isEmpty else {
            throw ProbeError(message: """
                the catalogue is empty. With Screen Recording granted there is always at \
                least one display; an empty list means the enumeration was filtered, not \
                that no displays are attached.
                """)
        }

        log("\(descriptors.count) capture sources")
        for descriptor in descriptors {
            let size = "\(Int(descriptor.pixelSize.width))×\(Int(descriptor.pixelSize.height))"
            // The icon is printed because its absence is invisible everywhere else: `nil` is a
            // valid, well-formed descriptor, and the client draws it as a generic symbol — so a
            // row that lost its icon and a row that was never meant to have one look identical
            // in the picker, and identical in the protocol. Only here do they differ.
            let icon = descriptor.iconPNGData.map { "\($0.count) B" } ?? "none"
            log("  \(descriptor.id.padding(toLength: 24, withPad: " ", startingAt: 0)) \(size.padding(toLength: 12, withPad: " ", startingAt: 0)) \(icon.padding(toLength: 7, withPad: " ", startingAt: 0)) \(descriptor.title)")
        }
    }

    // MARK: - Capture

    static func runCapture(_ options: Options) async throws {
        let resolver = ScreenCaptureSourceResolver()
        let descriptors = try await resolver.catalog().all
        guard let descriptor = pick(options.source, from: descriptors) else {
            let available = descriptors.map(\.id).joined(separator: ", ")
            throw ProbeError(message: "no source matches “\(options.source ?? "")”. Available: \(available)")
        }

        let size = descriptor.pixelSize
        log("capturing \(descriptor.title) [\(descriptor.id)] at \(Int(size.width))×\(Int(size.height))")

        let url = URL(fileURLWithPath: options.output)
        let writer = try MovieWriter(url: url, pixelSize: size, frameRate: options.frameRate)

        let geometry = GeometryRecorder()
        let pipeline = CapturePipeline(resolver: resolver)
        pipeline.onFrame = { frame in writer.append(frame) }
        pipeline.onGeometry = { frameGeometry in geometry.record(frameGeometry) }
        pipeline.onFailure = { error in
            log("!! pipeline failure: \(error.errorDescription ?? "\(error)")")
        }

        try await pipeline.start(source: descriptor.source, frameRate: options.frameRate)
        log("stream started; capturing for \(options.seconds)s")

        do {
            try await captureLoop(pipeline: pipeline, writer: writer, options: options)
        } catch {
            await pipeline.stop()
            throw error
        }

        let statistics = pipeline.statistics
        await pipeline.stop()

        let summary = try await writer.finish()
        report(pipeline: statistics, writer: summary, url: url)
        log(geometry.summary)
        try await playback(url: url)
    }

    /// Where two known colours land on the canvas, through the compositor's own arithmetic.
    ///
    /// **The one part of a mosaic that can be checked with no display, no TCC and no
    /// ScreenCaptureKit**, and the part most likely to be wrong in a way nothing else notices:
    /// a tile's rectangle is measured from the top left of the canvas while CoreImage puts its
    /// origin at the bottom left, and a flip that is the wrong way round draws a picture of
    /// windows in the wrong places rather than anything that looks broken.
    ///
    /// Two solid colours, then the canvas is read back at three points: the top-left tile's
    /// centre, the bottom-right tile's, and a corner neither of them touches.
    static func runComposeCheck() async throws {
        let canvas = CGSize(width: 64, height: 64)
        let red = CIImage(color: .red).cropped(to: CGRect(x: 0, y: 0, width: 32, height: 32))
        let green = CIImage(color: .green).cropped(to: CGRect(x: 0, y: 0, width: 32, height: 32))

        // The client's rectangles: the first tile at the canvas's top left, the second at its
        // bottom right, both a quarter of it.
        var composed = CIImage(color: .black).cropped(to: CGRect(origin: .zero, size: canvas))
        composed = MosaicCompositor.place(
            red, in: CGRect(x: 0, y: 0, width: 32, height: 32), canvas: canvas
        ).composited(over: composed)
        composed = MosaicCompositor.place(
            green, in: CGRect(x: 32, y: 32, width: 32, height: 32), canvas: canvas
        ).composited(over: composed)

        guard let pixels = render(composed, size: canvas) else {
            throw ProbeError(message: "the canvas could not be rendered")
        }

        // Sampling well inside each tile, so a border pixel of antialiasing cannot decide this.
        let topLeft = pixel(in: pixels, at: CGPoint(x: 16, y: 16))
        let bottomRight = pixel(in: pixels, at: CGPoint(x: 48, y: 48))
        let untouched = pixel(in: pixels, at: CGPoint(x: 48, y: 16))

        log("compose check: top left \(topLeft), bottom right \(bottomRight), top right \(untouched)")

        func isRed(_ colour: (r: Int, g: Int, b: Int)) -> Bool { colour.r > 180 && colour.g < 80 && colour.b < 80 }
        func isGreen(_ colour: (r: Int, g: Int, b: Int)) -> Bool { colour.g > 150 && colour.r < 80 && colour.b < 80 }
        func isBlack(_ colour: (r: Int, g: Int, b: Int)) -> Bool { colour.r < 60 && colour.g < 60 && colour.b < 60 }

        guard isRed(topLeft) else {
            throw ProbeError(message: "the first tile was asked for the canvas's top left and is at its bottom left: the vertical flip is the wrong way round")
        }
        guard isGreen(bottomRight) else {
            throw ProbeError(message: "the second tile is not where its rectangle said it would be")
        }
        guard isBlack(untouched) else {
            throw ProbeError(message: "the corner neither tile covers is not the canvas's own black")
        }
        log("compose check passed: the first tile is at the top left, the second at the bottom right, the rest is canvas")
    }

    /// Renders an image to a `BGRA` buffer and reads it, at the size it was given.
    ///
    /// `BGRA` rather than the canvas's own `420v`: this is checking where things are, and a
    /// colour space conversion between the check and the answer would be one more thing that
    /// could be what is wrong.
    private static func render(_ image: CIImage, size: CGSize) -> (data: Data, stride: Int, size: CGSize)? {
        var buffer: CVPixelBuffer?
        let attributes: [CFString: Any] = [
            kCVPixelBufferIOSurfacePropertiesKey: [:] as CFDictionary,
        ]
        guard CVPixelBufferCreate(
            kCFAllocatorDefault, Int(size.width), Int(size.height),
            kCVPixelFormatType_32BGRA, attributes as CFDictionary, &buffer
        ) == kCVReturnSuccess, let buffer else { return nil }

        CIContext().render(
            image,
            to: buffer,
            bounds: CGRect(origin: .zero, size: size),
            colorSpace: CGColorSpace(name: CGColorSpace.sRGB)
        )

        CVPixelBufferLockBaseAddress(buffer, .readOnly)
        defer { CVPixelBufferUnlockBaseAddress(buffer, .readOnly) }
        guard let base = CVPixelBufferGetBaseAddress(buffer) else { return nil }
        let stride = CVPixelBufferGetBytesPerRow(buffer)
        let data = Data(bytes: base, count: stride * Int(size.height))
        return (data, stride, size)
    }

    /// One pixel of a rendered check, at a point measured from the image's top left.
    private static func pixel(in rendered: (data: Data, stride: Int, size: CGSize), at point: CGPoint) -> (r: Int, g: Int, b: Int) {
        let x = min(max(Int(point.x), 0), Int(rendered.size.width) - 1)
        let y = min(max(Int(point.y), 0), Int(rendered.size.height) - 1)
        let offset = y * rendered.stride + x * 4
        guard offset + 3 < rendered.data.count else { return (0, 0, 0) }
        return (
            r: Int(rendered.data[offset + 2]),
            g: Int(rendered.data[offset + 1]),
            b: Int(rendered.data[offset])
        )
    }

    /// Several real sources composited into one canvas, through the host's own compositor.
    ///
    /// **The only check in this probe that runs more than one capture at a time**, and the one
    /// that answers the question a client would ask first: does a canvas built out of other
    /// people's pixel buffers encode into something that plays. Everything about it is the
    /// host's — one `SCStream` per tile, the retained copy, the CoreImage composite, the canvas
    /// pool, the encoder — and the only thing the probe supplies is the layout.
    static func runMosaic(_ options: Options) async throws {
        let resolver = ScreenCaptureSourceResolver()
        let descriptors = try await resolver.catalog().all

        var chosen: [CaptureSourceDescriptor] = []
        for spec in options.mosaic {
            guard let descriptor = pick(spec, from: descriptors) else {
                let available = descriptors.map(\.id).joined(separator: ", ")
                throw ProbeError(message: "no source matches “\(spec)”. Available: \(available)")
            }
            chosen.append(descriptor)
        }

        // A grid of the probe's own, and deliberately not `MosaicGrid`: that lives in the app's
        // kit, which this target does not link, and what is being proved here is the Mac's half
        // of the feature. Any rectangles would do; these are the ones the phone would send for
        // the same count.
        let count = chosen.count
        let columns = Int(ceil(Double(count).squareRoot()))
        let rows = Int(ceil(Double(count) / Double(columns)))
        let tiles = chosen.enumerated().map { index, descriptor in
            MosaicTile(
                source: descriptor.source,
                rect: NormalizedRect(
                    x: Double(index % columns) / Double(columns),
                    y: Double(index / columns) / Double(rows),
                    width: 1 / Double(columns),
                    height: 1 / Double(rows)
                )
            )
        }

        guard let layout = MosaicLayout(
            canvas: options.canvas,
            tiles: tiles,
            frameRate: min(options.frameRate, 30)
        ).validated else {
            throw ProbeError(message: "the mosaic had no tiles")
        }

        let names = chosen.map { "\($0.title) [\($0.id)]" }.joined(separator: " + ")
        log("""
            mosaic mode: \(count) asked for, \(layout.tiles.count) built — \(names) — in a \
            \(Int(layout.canvas.width))×\(Int(layout.canvas.height)) canvas at \(layout.frameRate) fps, \
            each tile its own SCStream
            """)

        let url = URL(fileURLWithPath: options.output)
        let writer = try MovieWriter(url: url, pixelSize: layout.canvas, frameRate: layout.frameRate)

        let pipeline = CapturePipeline(resolver: resolver)
        pipeline.onFrame = { frame in writer.append(frame) }
        pipeline.onFailure = { error in
            log("!! pipeline failure: \(error.errorDescription ?? "\(error)")")
        }

        try await pipeline.start(source: .mosaic(layout))
        log("mosaic source started; capturing for \(options.seconds)s")

        do {
            try await captureLoop(pipeline: pipeline, writer: writer, options: options)
        } catch {
            await pipeline.stop()
            throw error
        }

        let statistics = pipeline.statistics
        await pipeline.stop()

        let summary = try await writer.finish()
        report(pipeline: statistics, writer: summary, url: url)
        try await playback(url: url)
    }

    /// Waits out the capture window, forcing a keyframe partway through.
    static func captureLoop(
        pipeline: CapturePipeline,
        writer: MovieWriter,
        options: Options
    ) async throws {
        // A forced keyframe, mid-run, so the file shows one where it was asked for rather
        // than only at the two-second interval. The client-connect path does exactly this.
        let forceAt = min(1.0, options.seconds / 2)
        var forceSent = false
        var elapsed = 0.0

        while elapsed < options.seconds {
            try await Task.sleep(for: .milliseconds(100))
            elapsed += 0.1

            if !forceSent, elapsed >= forceAt {
                pipeline.requestKeyframe()
                log("requested a keyframe at \(String(format: "%.1f", elapsed))s")
                forceSent = true
            }

            // Five seconds of silence is the signature of a denied Screen Recording
            // permission: the stream reports no error, because from its point of view it
            // started successfully. Saying so beats reporting a successful run that wrote
            // an empty file.
            if elapsed >= 5, writer.frameCount == 0 {
                let statistics = pipeline.statistics
                throw ProbeError(message: """
                    no frames arrived after \(Int(elapsed))s \
                    (stream delivered \(statistics.framesDelivered), idle \(statistics.idleSamples)). \
                    ScreenCaptureKit reports no error in this state. Check that this process \
                    has Screen Recording permission — System Settings → Privacy & Security → \
                    Screen & System Audio Recording — and that it was launched after the \
                    grant; `--request-access` asks for it. `--synthetic` verifies the encoder \
                    without it.
                    """)
            }
        }
    }

    // MARK: - Synthetic

    static func runSynthetic(_ options: Options) async throws {
        let size = CGSize(width: 1280, height: 720)
        log("synthetic mode: \(Int(size.width))×\(Int(size.height)) generated frames, no capture")

        let url = URL(fileURLWithPath: options.output)
        let writer = try MovieWriter(url: url, pixelSize: size, frameRate: options.frameRate)
        let encoder = try VideoEncoder(pixelSize: size, frameRate: options.frameRate)
        encoder.onFrame = { frame in writer.append(frame) }

        let total = Int(options.seconds * Double(options.frameRate))
        log("encoding \(total) frames")

        for index in 0..<total {
            guard let frame = SyntheticSource.capturedFrame(index: index, frameRate: options.frameRate, pixelSize: size) else {
                throw ProbeError(message: "could not create frame \(index)")
            }
            if index == total / 2 {
                encoder.requestKeyframe()
                log("requested a keyframe at frame \(index) (\(String(format: "%.1f", Double(index) / Double(options.frameRate)))s)")
            }
            try encoder.encode(frame)
        }

        encoder.shutdown()
        let statistics = encoder.statistics
        let summary = try await writer.finish()
        report(pipeline: nil, writer: summary, url: url, statistics: statistics)
        try await playback(url: url)
    }

    // MARK: - Pipeline

    /// Drives the host's **real** `CapturePipeline` over a source that generates its own
    /// frames.
    ///
    /// ``runSynthetic(_:)`` proves the encoder, and it does that by calling ``VideoEncoder``
    /// directly — which leaves the object the session layer actually drives unverified, and
    /// the pipeline is where most of the rules live: the resize check, the encoder rebuild
    /// and the keyframe it owes, the statistics that combine two sets of counters, and the
    /// delivery of encoded frames to a consumer on a thread the caller does not own. This
    /// mode runs all of that with no ScreenCaptureKit involvement at all, so it works on a
    /// machine that has never been granted Screen Recording.
    ///
    /// Beyond "a file was written", it gathers three things that are otherwise assertions:
    ///
    /// - `pipeline.statistics` before the start, while running, and after the stop.
    /// - A keyframe requested partway through, and the frame it landed on. `requestKeyframe()`
    ///   runs pipeline → encoder → the next frame submitted, and the gap between the frame
    ///   count when it was asked for and the frame it arrived on *is* that path's latency.
    /// - The frame count 400 ms after `stop()` returned, which must not have moved.
    static func runPipeline(_ options: Options) async throws {
        let size = CGSize(width: 1280, height: 720)
        log("""
            pipeline mode: the host's CapturePipeline over generated frames, \
            \(Int(size.width))×\(Int(size.height)) @ \(options.frameRate) fps, no capture
            """)

        let url = URL(fileURLWithPath: options.output)
        let writer = try MovieWriter(url: url, pixelSize: size, frameRate: options.frameRate)
        let geometry = GeometryRecorder()

        let pipeline = CapturePipeline(syntheticPixelSize: size, frameRate: options.frameRate)
        pipeline.onFrame = { frame in writer.append(frame) }
        pipeline.onGeometry = { frameGeometry in geometry.record(frameGeometry) }
        pipeline.onFailure = { error in
            log("!! pipeline failure: \(error.errorDescription ?? "\(error)")")
        }

        log("statistics before start: \(describe(pipeline.statistics))")

        let startBegan = Date()
        try await pipeline.start(source: .display(0))
        // Taken after the start, so the rate measured below is a rate of *delivery* rather
        // than of delivery diluted by the encoder's session setup.
        let started = Date()
        let transform = pipeline.inputTransform()
        log("""
            start(source: .display(0)) returned after \
            \(Int(started.timeIntervalSince(startBegan) * 1000)) ms · \
            currentSource \(pipeline.currentSource?.stableID ?? "nil") · \
            inputTransform \(transform == .degenerate ? "degenerate (0×0, nothing to map into)" : "\(transform.map { "\(Int($0.pixelSize.width))×\(Int($0.pixelSize.height))" } ?? "nil")")
            """)

        let forceAt = min(1.0, options.seconds / 2)
        var forceSent = false
        var requestedAfterFrames: Int?
        var elapsed = 0.0

        while elapsed < options.seconds {
            try await Task.sleep(for: .milliseconds(100))
            elapsed += 0.1

            if !forceSent, elapsed >= forceAt {
                requestedAfterFrames = writer.frameCount
                pipeline.requestKeyframe()
                log("""
                    pipeline.requestKeyframe() at \(String(format: "%.1f", elapsed))s, \
                    after \(requestedAfterFrames ?? 0) frames had been written
                    """)
                forceSent = true
            }

            // A synthetic source has no permission to lose and no display to be static, so
            // silence here is a bug in the pipeline or the generator rather than a TCC
            // state — which is worth saying outright, because the same silence on the real
            // path means something else entirely.
            if elapsed >= 2, writer.frameCount == 0 {
                let statistics = pipeline.statistics
                throw ProbeError(message: """
                    no frames arrived through the pipeline after \(Int(elapsed))s \
                    (delivered \(statistics.framesDelivered), idle \(statistics.idleSamples), \
                    encoded \(statistics.framesEncoded)). Nothing on this path needs Screen \
                    Recording permission, so this is a pipeline or generator bug.
                    """)
            }
        }

        let running = pipeline.statistics
        // Measured against the wall clock rather than against the loop's own count: the
        // loop sleeps in 100 ms steps and a step that overshoots is time the source had to
        // deliver frames in, so the loop's idea of "5 seconds" is the wrong denominator.
        let wallClock = Date().timeIntervalSince(started)
        log("""
            statistics after \(String(format: "%.1f", options.seconds))s of looping, \
            \(String(format: "%.2f", wallClock))s of wall clock: \(describe(running)) \
            (that is \(String(format: "%.1f", Double(running.framesDelivered) / wallClock)) fps \
            delivered, against the \(options.frameRate) asked for)
            """)

        await pipeline.stop()
        let framesAtStop = writer.frameCount
        let stopped = pipeline.statistics

        // Nothing may be delivered after stop: the encoder has been released by then, and a
        // frame arriving afterwards would be handed to a session that no longer exists.
        try await Task.sleep(for: .milliseconds(400))
        let framesLater = writer.frameCount

        log("""
            statistics after stop: \(describe(stopped)) — the encoder is released on stop, \
            so its counters read zero; the stream counters are the ones that survive
            """)
        log("""
            frames 400 ms after stop() returned: \(framesLater), \
            \(framesLater == framesAtStop
                ? "unchanged — the source stopped cleanly"
                : "\(framesLater - framesAtStop) more — the source delivered after stop")
            """)

        let summary = try await writer.finish()
        report(pipeline: running, writer: summary, url: url)
        reportKeyframe(
            summary: summary,
            requestedAfterFrames: requestedAfterFrames,
            frameRate: options.frameRate
        )
        log(geometry.summary)
        try await playback(url: url)
    }

    /// Where the requested keyframe landed, in the terms the request was made in.
    ///
    /// The generator's presentation times are frame indices over the frame rate, so a
    /// keyframe's position in the file is the frame it was attached to. That converts "the
    /// request went through the pipeline and came out on the next frame" from a claim into
    /// a measurement — and a request that never reached the encoder shows up as a keyframe
    /// only at the two-second interval, or at the start of the file.
    static func reportKeyframe(
        summary: MovieWriter.Summary,
        requestedAfterFrames: Int?,
        frameRate: Int
    ) {
        let frames = summary.keyframeSeconds.map { Int(($0 * Double(frameRate)).rounded()) }
        log("keyframes at frames: \(frames.map(String.init).joined(separator: ", "))")

        guard let requestedAfterFrames else {
            log("no keyframe was requested mid-run")
            return
        }
        guard let landed = frames.first(where: { $0 >= requestedAfterFrames }) else {
            log("""
                !! no keyframe at or after frame \(requestedAfterFrames): the request never \
                reached the encoder, or its output never came back
                """)
            return
        }
        log("""
            requested after frame \(requestedAfterFrames); the keyframe landed on frame \
            \(landed), \(landed - requestedAfterFrames) frames later
            """)
    }

    /// One line per set of counters, in the order the pipeline's `Statistics` documents them.
    static func describe(_ statistics: CapturePipeline.Statistics) -> String {
        """
        stream delivered \(statistics.framesDelivered), idle \(statistics.idleSamples) · \
        encoder encoded \(statistics.framesEncoded), dropped \(statistics.framesDropped)
        """
    }

    // MARK: - Reporting

    static func report(
        pipeline: CapturePipeline.Statistics?,
        writer: MovieWriter.Summary,
        url: URL,
        statistics: VideoEncoder.Statistics? = nil
    ) {
        if let pipeline {
            log("""
                stream: \(pipeline.framesDelivered) frames delivered, \
                \(pipeline.idleSamples) idle samples (a static display reports idle, not loss)
                """)
        }
        log("""
            encoder: \(statistics?.encoded ?? pipeline?.framesEncoded ?? 0) frames encoded, \
            \(statistics?.dropped ?? pipeline?.framesDropped ?? 0) dropped
            """)
        log("""
            file: \(writer.frames) frames, \(writer.bytes) bytes → \(url.path) \
            (\(writer.dropped) frames the writer could not take)
            """)
        log("keyframes at: \(writer.keyframeSeconds.map { String(format: "%.2fs", $0) }.joined(separator: ", "))")
    }

    static func playback(url: URL) async throws {
        let report = try await PlaybackCheck.run(url: url)
        log("""
            playback: \(report.framesDecoded) frames decoded, \
            \(String(format: "%.2f", report.duration))s, \
            \(Int(report.pixelSize.width))×\(Int(report.pixelSize.height)), \
            last frame mean luma \(String(format: "%.1f", report.lastFrameLuma))
            """)

        guard report.framesDecoded > 0 else {
            throw ProbeError(message: "the file decodes to zero frames")
        }
    }

    // MARK: - Helpers

    static func pick(_ query: String?, from descriptors: [CaptureSourceDescriptor]) -> CaptureSourceDescriptor? {
        guard let query, !query.isEmpty else {
            // The main display unless something else is asked for: the probe's default has
            // to be the thing a user means by "the screen".
            let main = CGMainDisplayID()
            return descriptors.first { $0.source == .display(main) }
                ?? descriptors.first { $0.kind == .display }
        }
        return descriptors.first { $0.id == query }
            ?? descriptors.first { $0.title.localizedCaseInsensitiveContains(query) }
    }
}

/// Collects the per-frame geometry the pipeline reports, which arrives on the capture queue.
///
/// Only the counts and one sample are printed. The point is not the numbers but that they
/// arrive at all: a window source whose geometry never changes is a window that is not
/// being tracked, and that is a remote cursor that drifts.
final class GeometryRecorder: @unchecked Sendable {
    private let lock = NSLock()
    private var count = 0
    private var sample: String?

    func record(_ geometry: FrameGeometry) {
        lock.withLock {
            count += 1
            guard sample == nil, let content = geometry.contentRect else { return }
            let screen = geometry.screenRect.map { " on screen at \($0)" } ?? ""
            sample = "content \(content)\(screen), scale \(geometry.scaleFactor ?? 0)"
        }
    }

    var summary: String {
        let (count, sample) = lock.withLock { (self.count, self.sample) }
        guard let sample else { return "geometry: not reported by any frame" }
        return "geometry: reported on \(count) frames · \(sample)"
    }
}

/// Timestamped lines, so a run can be read as a sequence of events rather than a list.
func log(_ message: String) {
    let elapsed = Date().timeIntervalSince(start)
    print(String(format: "[%6.2fs] %@", elapsed, message))
    fflush(stdout)
}

private let start = Date()
