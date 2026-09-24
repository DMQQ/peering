import AppKit
import AVFoundation
import CoreImage
import CoreGraphics
import CoreMedia
import CoreVideo
import Foundation
import RemoteCore
import ScreenCaptureKit

/// Captures the screen, encodes it, writes a playable file, and plays it back.
///
/// This is the phase's exit criterion in executable form: *encoded frames land on disk and
/// play back*. It is not a unit test of the encoder — it runs the host's real
/// `CapturePipeline`, its real `CaptureEngine` and its real `VideoEncoder`, and then asks
/// AVFoundation to decode what came out.
///
/// The capture modes, and the pairs among them, are the point:
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
/// - `--resources` is the one mode whose subject is this process rather than the screen: it
///   samples the app's own CPU, memory and network on the host window's own timer and prints
///   each reading, then what the sampler costs per reading. No permission, no catalogue, no
///   client, and `--burn` gives it a known load so a reading that does not move is visible as
///   the failure it is.
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
        /// Draw the card that stands in for a tile with no picture, and read it back.
        var placeholderCheck = false
        /// Rearrange a running mosaic onto a canvas of a different shape. See ``runMosaicRearrange(_:)``.
        var mosaicRearrange = false
        /// Photograph every running application and read the pictures back off the catalogue.
        var thumbnails = false
        /// Make a display that exists only in software, hold it, and take it away.
        var virtualDisplay = false
        /// How many distinct virtual-display identities to keep alive together.
        var virtualDisplayCount = 1
        /// Stream the virtual display for the hold, instead of leaving it empty.
        var captureVirtualDisplay = false
        /// The size to make it at, defaulting to the shape the host builds for a phone.
        var virtualSize = VirtualDisplay.phoneShaped
        /// Ask the system for Screen Recording, which puts a prompt on screen.
        var requestAccess = false
        /// Sample this process's own CPU, memory and network, and print what it costs.
        var resources = false
        /// How many threads to keep busy in this process while sampling it. See
        /// ``runResources(_:)`` for why the probe loads itself.
        var burners = 0
        /// The interval between resource samples, in seconds.
        var interval: Double = 2

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

                case "--placeholder-check":
                    placeholderCheck = true

                case "--mosaic-rearrange":
                    // The same list shape as --mosaic, because it is the same list: the sources
                    // are the thing both modes are given, and two parsers for one list is two
                    // parsers that can disagree about what a comma means.
                    guard let value = iterator.next() else {
                        throw ProbeError(message: "--mosaic-rearrange needs a comma-separated list of ids or title fragments")
                    }
                    mosaic = value.split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) }
                    guard mosaic.count >= 2 else {
                        throw ProbeError(message: "--mosaic-rearrange needs two or more sources")
                    }
                    mosaicRearrange = true

                case "--thumbnails":
                    thumbnails = true

                case "--virtual-display":
                    virtualDisplay = true

                case "--virtual-count":
                    guard let value = iterator.next(), let count = Int(value), (1...3).contains(count) else {
                        throw ProbeError(message: "--virtual-count needs an integer from 1 through 3")
                    }
                    virtualDisplayCount = count

                case "--capture":
                    captureVirtualDisplay = true

                case "--virtual-size":
                    guard let value = iterator.next() else {
                        throw ProbeError(message: "--virtual-size needs WIDTHxHEIGHT")
                    }
                    let parts = value.lowercased().split(separator: "x").compactMap { Double($0) }
                    guard parts.count == 2, parts[0] > 1, parts[1] > 1 else {
                        throw ProbeError(message: "--virtual-size needs WIDTHxHEIGHT, like 1290x2796")
                    }
                    virtualSize = CGSize(width: parts[0], height: parts[1])

                case "--resources":
                    resources = true

                case "--burn":
                    guard let value = iterator.next(), let count = Int(value), count >= 0 else {
                        throw ProbeError(message: "--burn needs a thread count, zero or more")
                    }
                    burners = count

                case "--interval":
                    guard let value = iterator.next(), let seconds = Double(value), seconds > 0 else {
                        throw ProbeError(message: "--interval needs a positive number of seconds")
                    }
                    interval = seconds

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
                                [--thumbnails] [--virtual-display [--virtual-size WxH]
                                 [--virtual-count N]]
                                [--resources [--burn N] [--interval S]] [--request-access]

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
              --placeholder-check
                               draw the card a tile with no picture gets — an application with
                               no windows, a window that has closed — at three tile sizes, read
                               each one back to prove something was drawn, and leave the PNGs
                               in /tmp for the eye. Needs no Screen Recording
              --mosaic-rearrange A,B
                               start a mosaic of the named sources, then ask for the same
                               windows on a canvas of a different shape — a phone turned, as
                               the Mac sees it — and check that the captures were kept: the
                               tiles live before the change are still live after it, and the
                               canvas is the new one. Needs Screen Recording
              --thumbnails     photograph every application the way opening the Apps panel
                               makes the host do, read the pictures back off the catalogue, and
                               fail if not one of them arrived. Needs Screen Recording
              --virtual-display
                               make a display that exists only in software, print the display
                               list before, during and after it, hold it for --seconds, and
                               take it away. Fails if it never appears or never goes away.
                               This is the host's phone-shaped second monitor, which is a
                               private API with three silent failure modes
              --virtual-size WxH
                               the size to make the virtual display at (default 1290x2796,
                               the shape the host builds for a phone)
              --virtual-count N
                               keep N distinct virtual displays alive together (1...3), remove
                               the first while the others remain, then remove the rest. This
                               proves distinct product/serial identities and their modes coexist
              --capture        stream the virtual display for the whole hold through the
                               ordinary capture path, so the frames and the file it writes
                               are the proof that it is captureable at all
              --mosaic A,B,…   composite the named sources — stable ids or title fragments —
                               into one canvas through the host's MosaicCompositor, and write
                               the result. This is the only check that runs more than one
                               capture at a time, and it needs Screen Recording
              --request-access ask the system for Screen Recording, which puts a prompt on
                               screen and blocks until it is answered
              --resources      sample this process's own CPU, memory and network for --seconds
                               and print each reading, then what the sampler itself costs. The
                               same code the host window runs, over a synthetic byte counter
                               rising at a known rate. Needs no permission
              --burn N         keep N threads busy inside this process while sampling it, so a
                               figure that rose is this process's own work and a figure that
                               stayed flat while the machine was busy is the point of the panel
              --interval S     seconds between resource samples (default 2)
            """
        }
    }

    // MARK: - Entry point

    static func run() async throws {
        var options = Options()
        try options.parse(CommandLine.arguments.dropFirst())

        log("host capture probe")

        // Before the preflight, because this mode measures the process and not the screen: it
        // works with Screen Recording denied, which is also the state a Mac is in the first time
        // somebody wonders whether the app is heavy.
        if options.resources {
            try await runResources(options)
            return
        }

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

        if options.virtualDisplay {
            try await runVirtualDisplay(options)
        } else if options.thumbnails {
            try await runThumbnails()
        } else if options.composeCheck {
            try await runComposeCheck()
        } else if options.placeholderCheck {
            try await runPlaceholderCheck()
        } else if options.mosaicRearrange {
            try await runMosaicRearrange(options)
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

    // MARK: - Thumbnails

    /// Photographs every display and window, the way opening the Apps panel makes the host do.
    ///
    /// **The half of that feature no client can check.** The phone only ever sees the pictures
    /// arrive, so a host that produced none and a host that produced twenty that were all
    /// dropped by the byte budget look the same from there: a grid of empty tiles. This walks
    /// the whole host half in one run — the enumeration, one screenshot per source, the JPEG
    /// under the budget, and the attach to the catalogue the client actually reads — and fails
    /// if they do not line up.
    ///
    /// The second catalogue read is the point of the check rather than a convenience. A
    /// thumbnail that was captured and never attached is exactly as good as one that was never
    /// taken, and it is the failure the cache's key has to be right for: the pictures are filed
    /// by ``CaptureSource/stableID`` and looked up by ``CaptureSourceDescriptor/id``, which are
    /// the same string only as long as both ends keep deriving it the same way.
    ///
    /// Displays and windows rather than applications: the picker draws an application as its
    /// icon, and a picture of one is only ever taken here to prove the path. See
    /// ``ScreenCaptureSourceResolver/refreshSourceThumbnails()``.
    static func runThumbnails() async throws {
        let resolver = ScreenCaptureSourceResolver()
        let catalog = try await resolver.catalog()
        let sources = (catalog.displays + catalog.windows)

        guard !sources.isEmpty else {
            throw ProbeError(message: """
                the catalogue offers no displays and no windows, so there is nothing to \
                photograph. That is the enumeration failing rather than the pictures: it needs \
                Screen Recording granted, and it should always offer at least one display.
                """)
        }
        log("\(catalog.displays.count) display(s) and \(catalog.windows.count) window(s) offered")

        let began = ProcessInfo.processInfo.systemUptime
        await resolver.refreshSourceThumbnails()
        let elapsed = ProcessInfo.processInfo.systemUptime - began

        // Read back through the catalog, so the attach is part of what this proves.
        let readBack = try await resolver.catalog()
        let pictured = readBack.displays + readBack.windows

        var taken = 0
        var largest = 0
        var missing: [String] = []
        for descriptor in pictured {
            guard let thumbnail = descriptor.thumbnail else {
                missing.append(descriptor.title)
                continue
            }
            taken += 1
            largest = max(largest, thumbnail.jpegData.count)
            log("""
                  \(descriptor.id.padding(toLength: 24, withPad: " ", startingAt: 0)) \
                \("\(thumbnail.width)×\(thumbnail.height)".padding(toLength: 12, withPad: " ", startingAt: 0)) \
                \("\(thumbnail.jpegData.count) B".padding(toLength: 8, withPad: " ", startingAt: 0)) \
                \(descriptor.title)
                """)
        }

        log("""
            \(taken) of \(pictured.count) photographed in \(String(format: "%.2f", elapsed))s, \
            largest \(largest) B of \(SourceThumbnail.maximumByteCount) B
            """)

        guard taken > 0 else {
            throw ProbeError(message: """
                not one application produced a picture. **Check which Space is showing \
                before anything else**: ScreenCaptureKit photographs only windows that are on \
                screen, and the host offers every application on every Space by design, so a \
                Mac sitting on a desktop with no application windows on it produces exactly \
                this and nothing is wrong. Every refusal is logged under subsystem \
                pl.dmq.peering.host, category capture.
                """)
        }
        // Named rather than counted, because an application with no picture is the ordinary
        // case rather than a fault — see below — and the question worth answering is *which*,
        // not how many.
        if !missing.isEmpty {
            log("no picture for: \(missing.joined(separator: ", "))")
            log("""
                these are most often applications with no window on the Space this Mac is \
                showing: the catalogue lists windows on every desktop, and a window that is \
                not on screen has no picture to take
                """)
        }
    }

    // MARK: - Resources

    /// What this process costs, sampled the way the host window samples it.
    ///
    /// **The run that matters is the one where the Mac is busy and these numbers stay flat.** A
    /// figure that was really about the machine would look right in every idle run and be
    /// useless in the only situation the panel exists for, which is somebody wondering whether
    /// the thing running is this app or the ten other things they have open. `--burn` loads
    /// *this process*, and the check is that the figure rises; run it against a busy Mac with no
    /// load of its own and the check is that it does not move at all.
    ///
    /// The byte counter is synthetic, because in the host it comes from the streamer and there
    /// is no streamer here. It rises at a fixed 250 KB/s, so every rate this prints has an
    /// answer known in advance: the arithmetic between two readings being exactly the part
    /// that is silently wrong whenever it is wrong.
    static func runResources(_ options: Options) async throws {
        let cores = ProcessInfo.processInfo.activeProcessorCount
        let syntheticBytesPerSecond = 250_000.0
        log("resource probe · this process only · \(cores) cores")
        log("""
            sampling every \(options.interval)s for \(options.seconds)s\
            \(options.burners > 0 ? ", with \(options.burners) thread(s) burning CPU here" : "")
            """)

        let burners = startBurners(options.burners)
        defer { burners.forEach { $0.cancel() } }

        var sampler = HostResourceSampler()
        let began = ProcessInfo.processInfo.systemUptime
        // One reading before the first sleep, so the interval that is being measured starts
        // here. Sleeping first would throw away the first figure and make every run take one
        // interval longer than it says it does, which is the window's own arrangement too.
        sampler.sample(bytesSent: 0)
        while ProcessInfo.processInfo.systemUptime - began < options.seconds {
            try? await Task.sleep(for: .seconds(options.interval))
            let elapsed = ProcessInfo.processInfo.systemUptime - began
            sampler.sample(bytesSent: UInt64(elapsed * syntheticBytesPerSecond))
            log(reading(sampler))
        }

        burners.forEach { $0.cancel() }

        // What the sampler itself costs, which is worth an answer because it runs on the same
        // machine as the encoder. A thousand readings rather than one: a single `task_info` is
        // below the resolution of anything here that could time it.
        var counter = HostResourceSampler()
        let iterations = 1000
        let costBegan = ProcessInfo.processInfo.systemUptime
        for index in 0..<iterations {
            counter.sample(bytesSent: UInt64(index))
        }
        let each = (ProcessInfo.processInfo.systemUptime - costBegan) / Double(iterations)
        log(String(format: "sampler cost: %.2f µs per reading", each * 1_000_000))
    }

    /// One line per sample, in the words and the format the host window uses.
    private static func reading(_ sampler: HostResourceSampler) -> String {
        guard let rates = sampler.rates else {
            return "warming up · no interval yet"
        }
        return "cpu \(HostResourceSampler.cpuPercent(rates)) of this Mac "
            + "(\(HostResourceSampler.percent(rates.cpuOfOneCore)) of one core) · "
            + "memory \(HostResourceSampler.memoryText(sampler.memoryBytes)) · "
            + "sent \(HostResourceSampler.networkText(rates.bytesPerSecond))"
    }

    /// Keeps `count` threads busy in this process until they are cancelled.
    ///
    /// A detached task per burner rather than one task doing arithmetic in a loop: CPU time is
    /// charged per thread, so one thread burning loses in the figure to the eight cores it is
    /// not using, and the whole point of the mode is a reading that moves.
    private static func startBurners(_ count: Int) -> [Task<UInt64, Never>] {
        (0..<count).map { _ in
            Task.detached(priority: .high) {
                var value: UInt64 = 0x9E37_79B9_7F4A_7C15
                while !Task.isCancelled {
                    // A linear congruential step per spin, and the value is returned rather
                    // than discarded: the compiler is free to delete a loop whose result
                    // nothing wants, and a deleted loop is a burner that measures nothing.
                    value = value &* 6_364_136_223_846_793_005 &+ 1_442_695_040_888_963_407
                }
                return value
            }
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

    // MARK: - Rearranging a mosaic

    /// The same captures drawn into a canvas of a different shape: a phone turned, as the Mac
    /// sees it.
    ///
    /// **What this is for is the second and a half.** A rotation, or a return to an arrangement
    /// from one of its tiles, re-asks for the same windows in different rectangles — and until the
    /// rearrangement path existed the Mac answered by stopping a ScreenCaptureKit stream per tile
    /// and starting a new one, which is a visible stop in the picture for arithmetic the client had
    /// already done.
    ///
    /// So what is checked is not that it is faster, which a stopwatch would say and a bad week
    /// would disagree with: it is that the tiles were **never stopped**. A tile that is live
    /// before the rearrangement and still live immediately after it is a capture that survived,
    /// which is a thing no rebuild can be quick enough to imitate. The canvas is checked too,
    /// because a rearrangement that did not change what it draws would pass the first test and be
    /// no use to anybody. Needs Screen Recording.
    static func runMosaicRearrange(_ options: Options) async throws {
        let resolver = ScreenCaptureSourceResolver()
        let descriptors = try await resolver.catalog().all
        let chosen = options.mosaic.compactMap { fragment in
            descriptors.first {
                $0.id == fragment || $0.title.localizedCaseInsensitiveContains(fragment)
            }
        }
        guard chosen.count >= 2 else {
            throw ProbeError(message: """
                --mosaic-rearrange needs two or more capturable sources, given as stable ids or \
                title fragments after it. The catalogue has \(descriptors.count).
                """)
        }
        let catalog = try await resolver.catalog()

        /// One arrangement of the chosen windows, in a grid of the given shape.
        func plan(columns: Int, rows: Int, canvas: CGSize) -> MosaicPlan? {
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
            guard let layout = MosaicLayout(canvas: canvas, tiles: tiles, frameRate: 15).validated
            else { return nil }
            return MosaicPlan.make(layout: layout, catalog: catalog, resolver: resolver)
        }

        guard let sideways = plan(columns: 2, rows: 1, canvas: CGSize(width: 1280, height: 720)),
              let upright = plan(columns: 1, rows: 2, canvas: CGSize(width: 720, height: 1280)),
              !sideways.tiles.isEmpty, upright.tiles.count == sideways.tiles.count
        else {
            throw ProbeError(message: "two arrangements of those sources could not be built")
        }

        let drawn = FrameCanvasRecorder()

        let compositor = MosaicCompositor()
        compositor.onFrame = { frame in
            drawn.record(CGSize(
                width: CVPixelBufferGetWidth(frame.pixelBuffer),
                height: CVPixelBufferGetHeight(frame.pixelBuffer)
            ))
        }

        try await compositor.start(.mosaic(sideways))
        try await waitForFrames(drawn, atLeast: 1, describing: "a first canvas")
        // A little longer, because a tile's stream only sends a frame when its window changes: a
        // window nobody has touched may take a second or two to produce its first picture, and what
        // is being measured is the survival of the tiles that did.
        try await Task.sleep(for: .seconds(2))

        // **Only what has actually produced a picture counts**, and the number of them is the whole
        // of the measurement: a window that has sent nothing has no capture whose loss could be
        // detected, and requiring all of them would make this check fail on a quiet screen rather
        // than on a Mac that dropped its streams.
        let liveBefore = compositor.liveTileCount
        log("\(liveBefore) of \(sideways.tiles.count) tiles produced a picture on the \(Int(sideways.canvas.width))×\(Int(sideways.canvas.height)) canvas")
        guard liveBefore > 0 else {
            throw ProbeError(message: """
                not one of those sources produced a picture in two seconds, so there is nothing whose \
                survival the rearrangement could be measured by. Try sources that are doing something.
                """)
        }

        try await compositor.replan(upright)
        // **At the new size, not merely one more frame.** A tick that was already in flight when
        // the canvas changed draws the old one, and it arrives after the rearrangement — so
        // "something was drawn since" is satisfied by exactly the frame that proves nothing. What
        // is waited for is the first canvas that comes out the shape of the one asked for.
        try await waitForCanvas(drawn, toBe: upright.canvas)

        let survivors = compositor.liveTileCount
        log("\(survivors) tiles live on a \(Int(upright.canvas.width))×\(Int(upright.canvas.height)) canvas")
        guard survivors >= liveBefore else {
            throw ProbeError(message: """
                the rearrangement lost \(liveBefore - survivors) of its \(liveBefore) captures. The \
                tiles are supposed to be kept and only the canvas replaced — see \
                MosaicCompositor.replan.
                """)
        }
        guard let canvas = drawn.last, canvas == upright.canvas else {
            throw ProbeError(message: """
                the frame after the rearrangement came out \(drawn.last.map { "\(Int($0.width))×\(Int($0.height))" } ?? "not at all") \
                and the new canvas is \(Int(upright.canvas.width))×\(Int(upright.canvas.height))
                """)
        }

        // **And again with the windows moved between the slots**, which is what a long press on a
        // tile does: the same canvas, the same rectangles, and a different window in each. A
        // rearrangement that matched captures by their place in the plan would call this six new
        // captures and build six new streams, so the check that the tiles are still live is exactly
        // the check that a reorder costs a re-composite.
        guard var swapped = plan(columns: 1, rows: 2, canvas: CGSize(width: 720, height: 1280)) else {
            throw ProbeError(message: "the reordered arrangement could not be built")
        }
        swapped = MosaicPlan(
            canvas: swapped.canvas,
            frameRate: swapped.frameRate,
            tiles: swapped.tiles.reversed(),
            placeholders: swapped.placeholders
        )
        try await compositor.replan(swapped)
        try await waitForCanvas(drawn, toBe: swapped.canvas)

        let afterSwap = compositor.liveTileCount
        guard afterSwap >= liveBefore else {
            throw ProbeError(message: """
                a reorder lost \(liveBefore - afterSwap) of its \(liveBefore) captures. The windows \
                take their streams with them — see MosaicCompositor.canReuseCaptures.
                """)
        }
        log("\(afterSwap) tiles still live after moving every window to the other slot")

        await compositor.stop()
        log("mosaic rearrange check passed: the captures were kept, the canvas is the new one, and a reorder kept them too")
    }

    /// Waits for the canvas to have been drawn a given number of times, or gives up.
    ///
    /// Generous, because the thing being waited for is a screen that may be perfectly still: a
    /// compositor draws on its own tick whether or not anything moved, so this is a wait on a timer
    /// rather than on a change, and a slow Mac is not a failure.
    private static func waitForFrames(
        _ drawn: FrameCanvasRecorder,
        atLeast target: Int,
        describing what: String
    ) async throws {
        let deadline = Date().addingTimeInterval(10)
        while drawn.count < target {
            if Date() >= deadline {
                throw ProbeError(message: "no \(what) arrived within ten seconds")
            }
            try await Task.sleep(for: .milliseconds(50))
        }
    }

    /// Waits for a canvas of a given size to have been drawn, or gives up.
    private static func waitForCanvas(_ drawn: FrameCanvasRecorder, toBe canvas: CGSize) async throws {
        let deadline = Date().addingTimeInterval(10)
        while drawn.last != canvas {
            if Date() >= deadline { return }
            try await Task.sleep(for: .milliseconds(50))
        }
    }

    // MARK: - The empty tile's card

    /// The card that stands in for a tile with no picture, drawn and read back.
    ///
    /// **The failure this catches is silence.** A card is a symbol and two lines of text drawn
    /// into a bitmap, and every way of getting it wrong has the same result as the black
    /// rectangle it replaced: a symbol that does not exist on this macOS, a font size that rounds
    /// to nothing at tile scale, a block measured in the wrong direction, a flip that puts the
    /// text above the top edge. None of those would ever be read as a bug in the card — the user
    /// would see a black tile in a mosaic and conclude the app had failed at something.
    ///
    /// So each card is drawn at three tile sizes, read back off a render, and required to have
    /// something bright down its middle. The PNGs are left in /tmp as well, because "not uniformly
    /// black" is a much weaker claim than "reads as a card", and only an eye can settle that.
    static func runPlaceholderCheck() async throws {
        let cards: [(name: String, content: MosaicPlaceholder.Content, size: CGSize)] = [
            (
                "application",
                MosaicPlaceholder.Content(title: "Numbers", message: "No windows open", icon: nil),
                CGSize(width: 853, height: 480)
            ),
            (
                "window",
                MosaicPlaceholder.Content(title: nil, message: "This window has closed", icon: nil),
                CGSize(width: 480, height: 270)
            ),
            // Nine tiles on a landscape canvas, which is the smallest a card is drawn in today.
            (
                "ninth",
                MosaicPlaceholder.Content(title: "Mail", message: "No windows open", icon: nil),
                CGSize(width: 853, height: 480 - 480 / 3)
            ),
        ]

        for card in cards {
            guard let image = MosaicPlaceholder.image(card.content, size: card.size) else {
                throw ProbeError(message: """
                    the \(card.name) card could not be drawn at \
                    \(Int(card.size.width))×\(Int(card.size.height))
                    """)
            }
            guard let pixels = render(image, size: card.size) else {
                throw ProbeError(message: "the \(card.name) card could not be rendered")
            }

            // Down the middle, because the block is centred: the mark, the name and the reason
            // are all crossed by that line, and a card that drew nothing is black the whole way.
            let brightest = stride(from: 0.08, through: 0.92, by: 0.04)
                .map { pixel(in: pixels, at: CGPoint(x: card.size.width / 2, y: card.size.height * $0)) }
                .map { max($0.r, max($0.g, $0.b)) }
                .max() ?? 0
            guard brightest > 90 else {
                throw ProbeError(message: """
                    the \(card.name) card came out black: nothing was drawn in it, which on a \
                    phone is indistinguishable from the tile it was meant to explain
                    """)
            }

            let url = URL(fileURLWithPath: "/tmp/maccast-card-\(card.name).png")
            if let cgImage = CIContext().createCGImage(image, from: image.extent),
               let data = NSBitmapImageRep(cgImage: cgImage).representation(using: .png, properties: [:]) {
                try? data.write(to: url)
            }
            log("\(card.name) card at \(Int(card.size.width))×\(Int(card.size.height)): brightest \(brightest)/255, written to \(url.path)")
        }

        log("placeholder check passed: every card drew something, and the pictures are in /tmp")
    }

    // MARK: - Virtual display

    /// Makes a display that exists only in software, and proves that it appeared and went away.
    ///
    /// **The check is the whole exercise.** `CGVirtualDisplay` is a private CoreGraphics class
    /// with no header, and every one of its failure modes is quiet: a selector that has been
    /// renamed upstream raises an `NSException` this process cannot catch, a descriptor with a
    /// field the system wants and does not get is accepted and never shows a display, and a
    /// display that is made and never removed is a monitor on the user's Mac with no switch
    /// attached to it. So this mode asks the window server for its display list three times, at
    /// the three moments that matter, and exits non-zero if the second is the same as the first
    /// or the third is not empty of it.
    static func runVirtualDisplay(_ options: Options) async throws {
        guard VirtualDisplay.isAvailable else {
            throw ProbeError(message: """
                this Mac's system software has no CGVirtualDisplay class, so the host's virtual \
                display cannot exist here. There is no fallback to look for either: a display that \
                is not a panel is a thing only the window server can make.
                """)
        }

        // AppKit's screen list is read before the display exists, on purpose: that is the state
        // every running host is in, because it reads the list to build the catalogue for the
        // first client that connects. **A process that has already materialised its `NSScreen`
        // list does not see a virtual display appear in it afterwards** (measured, with an
        // `NSApplication` and its run loop turning), while a process that reads the list for the
        // first time after the display exists does see it. So this one line is the difference
        // between checking what a host sees and checking what a fresh process sees, and it is
        // what makes the naming below a real test of ``VirtualDisplay/name(for:)``.
        _ = NSScreen.screens

        let before = VirtualDisplay.activeDisplayIDs()
        log("displays before: \(described(before))")

        var displays: [VirtualDisplay] = []
        for offset in 0..<options.virtualDisplayCount {
            displays.append(try VirtualDisplay(
                size: options.virtualSize,
                name: "Capture Probe \(offset + 1)",
                serialNumber: UInt32(offset + 1),
                productID: 0x5045 + UInt32(offset),
                isPhoneManaged: true
            ))
            for display in displays { _ = display.restoreCurrentMode() }
        }
        let displayIDs = displays.map(\.displayID)
        guard Set(displayIDs).count == displays.count else {
            throw ProbeError(message: "multiple virtual displays were assigned the same display ID: \(displayIDs)")
        }
        let after = VirtualDisplay.activeDisplayIDs()
        log("displays after:  \(described(after))")

        // `init` already waited for this. Asked again because the exit criterion is stated in
        // terms of the display list, and the list is the thing a reader has to be able to see.
        guard displayIDs.allSatisfy(after.contains) else {
            throw ProbeError(message: """
                displays were created as \(displayIDs) and the window server's list does not have \
                all of them: \(described(after))
                """)
        }

        for displayID in displayIDs {
            let bounds = CGDisplayBounds(displayID)
            let millimetres = CGDisplayScreenSize(displayID)
            log("""
                display \(displayID) at \(Int(bounds.origin.x)),\(Int(bounds.origin.y)) · \
                \(Int(bounds.width))×\(Int(bounds.height)) points · \
                \(CGDisplayPixelsWide(displayID))×\(CGDisplayPixelsHigh(displayID)) pixels · \
                panel \(Int(millimetres.width))×\(Int(millimetres.height)) mm
                """)
            let expectedWidth = Int(options.virtualSize.height)
            let expectedHeight = Int(options.virtualSize.width)
            guard CGDisplayPixelsWide(displayID) == expectedWidth,
                  CGDisplayPixelsHigh(displayID) == expectedHeight
            else {
                let modes = (CGDisplayCopyAllDisplayModes(displayID, nil) as? [CGDisplayMode] ?? [])
                    .map { "\($0.pixelWidth)×\($0.pixelHeight)" }
                    .joined(separator: ", ")
                throw ProbeError(message: """
                    display \(displayID) lost its requested landscape mode: expected \
                    \(expectedWidth)×\(expectedHeight), got \
                    \(CGDisplayPixelsWide(displayID))×\(CGDisplayPixelsHigh(displayID)); modes: \(modes)
                    """)
            }
        }

        // Whether the display is still invisible to AppKit, which is the reason the host names
        // it from its own registry rather than from `NSScreen` (see the note above).
        let inAppKit = NSScreen.screens.contains { screen in
            let number = screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber
            return displayIDs.contains(number?.uint32Value ?? 0)
        }
        log("AppKit: \(inAppKit ? "in NSScreen.screens" : "not in NSScreen.screens, so the catalogue must name it")")

        for displayID in displayIDs { try await checkCatalogueHas(displayID) }

        if options.captureVirtualDisplay {
            // The hold, spent streaming it. Everything downstream is the probe's ordinary capture
            // path, reached with the display the host would have offered: that is the point of
            // asking for it this way, because a stream that went through a special case for
            // virtual displays would prove the special case and not the feature.
            var capture = options
            capture.source = "display:\(displayIDs[0])"
            log("streaming it for \(String(format: "%.1f", options.seconds))s")
            try await runCapture(capture)
        } else {
            log("holding for \(String(format: "%.1f", options.seconds))s")
            try await Task.sleep(for: .seconds(options.seconds))
        }

        let firstID = displayIDs[0]
        let removed = displays.removeFirst().remove()
        let afterFirstRemoval = VirtualDisplay.activeDisplayIDs()
        guard removed,
              !afterFirstRemoval.contains(firstID),
              displays.allSatisfy({ afterFirstRemoval.contains($0.displayID) })
        else {
            throw ProbeError(message: """
                removing the first virtual display disturbed another one: \
                \(described(afterFirstRemoval))
                """)
        }
        for display in displays {
            guard display.remove() else {
                throw ProbeError(message: "virtual display \(display.displayID) did not leave")
            }
        }
        let end = VirtualDisplay.activeDisplayIDs()
        log("displays after teardown: \(described(end))")
        guard displayIDs.allSatisfy({ !end.contains($0) }) else {
            throw ProbeError(message: """
                a virtual display was torn down and is still there: \(described(end)). A display \
                that outlives its object is a monitor the user cannot get rid of, and once this \
                process has exited there is nothing left holding a switch for it.
                """)
        }

        log("""
            virtual display OK · \(displays.count + 1) at \
            \(Int(options.virtualSize.width))×\(Int(options.virtualSize.height)) appeared as \
            \(displayIDs) and left independently when released
            """)
    }

    /// Whether the capture pipeline is offered the display, which is the difference between a
    /// second monitor and a second monitor the phone can be shown.
    ///
    /// ScreenCaptureKit keeps a list of its own, and every filter the pipeline builds comes out
    /// of that list: a display the window server has and ScreenCaptureKit does not is one the
    /// catalogue cannot offer and no stream can be started from. Asked repeatedly rather than
    /// once, because a display made a moment ago may not be in an enumeration cached on the far
    /// side of a daemon, and reading the catalogue at all takes Screen Recording permission,
    /// which is a reason to report that this went unchecked rather than to fail.
    private static func checkCatalogueHas(_ displayID: CGDirectDisplayID) async throws {
        let deadline = Date().addingTimeInterval(5)

        while true {
            let displays: [CaptureSourceDescriptor]
            do {
                displays = try await ScreenCaptureSourceResolver().catalog().displays
            } catch {
                log("catalogue: not checked, \(error.localizedDescription)")
                return
            }

            if let row = displays.first(where: { $0.source == .display(displayID) }) {
                log("""
                    catalogue: offered as “\(row.title)” at \
                    \(Int(row.pixelSize.width))×\(Int(row.pixelSize.height))
                    """)
                return
            }

            if Date() >= deadline {
                let ids = displays.compactMap { descriptor -> UInt32? in
                    if case .display(let id) = descriptor.source { return id }
                    return nil
                }.sorted()
                throw ProbeError(message: """
                    the display is on screen and ScreenCaptureKit does not enumerate it, so the \
                    host would offer the phone every display except the one it made on purpose. \
                    Displays it does list: \(ids.map(String.init).joined(separator: ", "))
                    """)
            }
            try? await Task.sleep(for: .milliseconds(500))
        }
    }

    /// A display list as one line: each display's id, where macOS put it, and how big it is.
    ///
    /// The origin as well as the size, because where a new display lands is how the user finds
    /// it: a display placed on top of another one comes with every window on top of it.
    static func described(_ displays: [CGDirectDisplayID]) -> String {
        guard !displays.isEmpty else { return "none" }
        return displays.map { displayID in
            let bounds = CGDisplayBounds(displayID)
            return "\(displayID)@\(Int(bounds.origin.x)),\(Int(bounds.origin.y)) "
                + "\(Int(bounds.width))×\(Int(bounds.height))"
        }.joined(separator: " · ")
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
/// The canvases a compositor drew, in order, from whichever queue drew them.
///
/// A class with a lock rather than an array captured in a closure: the compositor delivers on its
/// own serial queue and the check reads from the main actor, which is the same pair of threads that
/// made this necessary everywhere else in this app.
final class FrameCanvasRecorder: @unchecked Sendable {
    private let lock = NSLock()
    private var sizes: [CGSize] = []

    func record(_ size: CGSize) { lock.withLock { sizes.append(size) } }

    var count: Int { lock.withLock { sizes.count } }
    var last: CGSize? { lock.withLock { sizes.last } }
}

func log(_ message: String) {
    let elapsed = Date().timeIntervalSince(start)
    print(String(format: "[%6.2fs] %@", elapsed, message))
    fflush(stdout)
}

private let start = Date()
