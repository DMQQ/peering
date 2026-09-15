import CoreMedia
import CoreVideo
import Foundation
import RemoteCore
import ScreenCaptureKit
import os

private let pipelineLog = Logger(subsystem: "pl.dmq.peering.host", category: "capture")

/// Capture and encode, as one thing the session can drive.
///
/// The session layer should not have to know that a stream and an encoder are two objects
/// with a lifetime between them — that a window resized past the encoder's dimensions needs
/// the encoder rebuilt, that a rebuilt encoder owes the client a keyframe, that a source
/// switch is really a teardown plus a setup plus a fresh keyframe. Those rules live here.
///
/// Everything runs on the capture queue that ``CaptureEngine`` delivers frames on, which is
/// serial. That is what makes the encoder swap below safe without a lock of its own.
///
/// A pipeline is built over one of two backends, and the difference is confined to how a
/// session starts: a real one reads the catalogue and builds a filter, a synthetic one
/// generates its own frames. Everything after that — the resize check, the encoder swap,
/// the keyframe bookkeeping, the statistics, the delivery of `EncodedFrame`s — is the same
/// code on both paths, which is what makes the synthetic path worth having. See
/// ``init(syntheticPixelSize:frameRate:codec:)``.
final class CapturePipeline: @unchecked Sendable {
    /// Where frames come from, and what starting one takes.
    ///
    /// Two cases rather than an optional resolver: the synthetic path must not merely skip
    /// the resolver, it must be unable to reach it. Everything ScreenCaptureKit would be
    /// asked for on this path — a catalogue, a filter, an `SCDisplay` — either fails or
    /// gets the process killed when Screen Recording has not been granted, and a path that
    /// cannot compile a call to them cannot be tempted into one.
    private enum Backend {
        case capture(resolver: CaptureSourceResolver, engine: CaptureEngine)
        case synthetic(engine: SyntheticCaptureEngine)
    }

    private let backend: Backend
    private let codec: VideoCodec
    private let lock = NSLock()

    private var encoder: VideoEncoder?
    private var source: CaptureSource?
    /// Set when the client must be sent a keyframe before it can decode anything, and
    /// cleared when one goes out. Held here rather than only in the encoder because the
    /// encoder can be replaced mid-flight, and a request that dies with the old session
    /// leaves the client staring at a picture that never resolves.
    private var awaitsKeyframe = false

    private var _onFrame: (@Sendable (EncodedFrame) -> Void)?
    private var _onGeometry: (@Sendable (FrameGeometry) -> Void)?
    private var _onFailure: (@Sendable (CaptureError) -> Void)?

    /// Encoded frames, in order, on VideoToolbox's thread.
    var onFrame: (@Sendable (EncodedFrame) -> Void)? {
        get { lock.withLock { _onFrame } }
        set { lock.withLock { _onFrame = newValue } }
    }

    /// Where the captured content currently sits, reported per frame. A window that is
    /// dragged or resized changes this with no notification, so it is the only way the input
    /// mapping can stay correct for anything but a display.
    var onGeometry: (@Sendable (FrameGeometry) -> Void)? {
        get { lock.withLock { _onGeometry } }
        set { lock.withLock { _onGeometry = newValue } }
    }

    /// The stream stopped on its own — sleep/wake, a display change, a revoked permission.
    var onFailure: (@Sendable (CaptureError) -> Void)? {
        get { lock.withLock { _onFailure } }
        set { lock.withLock { _onFailure = newValue } }
    }

    /// The source of frames, whichever kind it is.
    private var engine: any CaptureFrameSource {
        switch backend {
        case .capture(_, let engine): return engine
        case .synthetic(let engine): return engine
        }
    }

    init(resolver: CaptureSourceResolver, codec: VideoCodec = .h264) {
        self.backend = .capture(resolver: resolver, engine: CaptureEngine())
        self.codec = codec
    }

    /// A pipeline that generates its own frames instead of capturing the screen.
    ///
    /// This is the seam that lets the real pipeline run where Screen Recording has not been
    /// granted — on CI, or on a machine whose grant cannot be obtained. `start(source:)`
    /// still has to be called, and still returns only once frames may begin arriving, but
    /// nothing on this path reads the catalogue, builds a filter, or constructs any
    /// ScreenCaptureKit object: the source it is handed is recorded rather than looked up.
    ///
    /// What it exercises is everything downstream of the stream, which is the reason it
    /// exists: the frame intake and its size check, the encoder rebuild when the surface
    /// changes size, the keyframe a rebuilt encoder owes, the statistics that combine
    /// stream and encoder counters, and the hand-off of `EncodedFrame`s to ``onFrame`` on a
    /// thread that is not the caller's. What it cannot exercise is ScreenCaptureKit itself
    /// — the pixel format and the content rect are generated rather than negotiated.
    ///
    /// - Parameters:
    ///   - syntheticPixelSize: The size to generate, in pixels. Rounded to even dimensions
    ///     the same way ``VideoEncoder`` rounds a capture size, so what arrives matches what
    ///     the encoder was built for.
    ///   - frameRate: Frames per second, fixed here rather than at `start`: the rate is part
    ///     of what the generator was built with, exactly as a stream's rate is part of its
    ///     configuration.
    init(syntheticPixelSize: CGSize, frameRate: Int = 60, codec: VideoCodec = .h264) {
        self.backend = .synthetic(
            engine: SyntheticCaptureEngine(pixelSize: syntheticPixelSize, frameRate: frameRate)
        )
        self.codec = codec
    }

    /// What is being captured, or `nil` while stopped.
    var currentSource: CaptureSource? {
        lock.withLock { source }
    }

    /// Everything worth knowing about a running session, in one value.
    ///
    /// Both halves are here because the failures they distinguish look identical from
    /// outside: a stream delivering nothing, a stream delivering frames the encoder drops,
    /// and an encoder that is simply not being fed are all "the client sees nothing".
    struct Statistics: Sendable, Equatable {
        /// Frames the stream delivered that carried a picture.
        let framesDelivered: Int
        /// Sample buffers that carried no new picture — a static display, a blank one, or a
        /// stopped stream. Not frame loss.
        let idleSamples: Int
        /// Frames handed to the network.
        let framesEncoded: Int
        /// Frames the encoder discarded because it could not keep up.
        let framesDropped: Int
    }

    var statistics: Statistics {
        let engineStatistics = engine.statistics
        let encoderStatistics = lock.withLock { encoder }?.statistics
        return Statistics(
            framesDelivered: engineStatistics.delivered,
            idleSamples: engineStatistics.idle,
            framesEncoded: encoderStatistics?.encoded ?? 0,
            framesDropped: encoderStatistics?.dropped ?? 0
        )
    }

    /// Where client coordinates map to for the active source, built from catalogue-time
    /// geometry. Prefer the per-frame content rect from ``onGeometry`` for windows and
    /// applications, whose content moves without anything announcing it.
    ///
    /// A synthetic pipeline answers ``InputTransform/degenerate``: generated frames are of
    /// no screen, so there is no coordinate space for a client's input to land in. The
    /// answer is still `nil` while stopped, so the shape of the answer does not depend on
    /// which backend is underneath.
    func inputTransform() -> InputTransform? {
        switch backend {
        case .capture(let resolver, _):
            return lock.withLock { source }.map { resolver.inputTransform(for: $0) }
        case .synthetic:
            return lock.withLock { source }.map { _ in .degenerate }
        }
    }

    /// The capture sources the host is currently offering.
    ///
    /// A synthetic pipeline has no sources and answers with an empty list rather than
    /// refusing. The caller is populating a picker, and "nothing to pick" is a true answer
    /// where an error would be a spurious one — there is no such thing as a generated source
    /// a client could ask for by name.
    func catalog() async throws -> CaptureCatalog {
        switch backend {
        case .capture(let resolver, _): return try await resolver.catalog()
        case .synthetic: return CaptureCatalog()
        }
    }

    // MARK: - Lifecycle

    /// Starts capturing a source, replacing whatever was being captured before.
    ///
    /// The catalogue is re-read first. The source came from the client, which chose it from
    /// a list that may be seconds old by the time a first frame is wanted: the window may
    /// have been closed, or the display unplugged. Failing here, with a message naming the
    /// source, is the difference between "the client cannot connect" and "the window you
    /// picked is gone".
    ///
    /// A synthetic pipeline takes the source as given — there is no catalogue to check it
    /// against and nothing to build a filter from — and uses the frame rate it was built
    /// with. It cannot fail, which is deliberate: the caller that has to be able to run on
    /// a machine without Screen Recording permission is the caller that cannot afford an
    /// error here.
    func start(source: CaptureSource, frameRate: Int = 60) async throws {
        await stop()

        switch backend {
        case .capture(let resolver, let engine):
            let catalog = try await resolver.catalog()
            guard let descriptor = catalog.all.first(where: { $0.source == source }) else {
                throw CaptureError.sourceUnavailable("That capture source is no longer available.")
            }

            let plan = try resolver.makeFilter(for: source)
            let configuration = try CaptureEngine.configuration(for: descriptor, frameRate: frameRate)
            // Set after the configuration is built rather than inside it: the rectangle belongs
            // to the filter — it is expressed in that filter's coordinate space — and
            // `CaptureEngine` is handed only a descriptor. See ``CaptureFilterPlan``.
            if let sourceRect = plan.sourceRect {
                configuration.sourceRect = sourceRect
            }
            let encoder = try VideoEncoder(codec: codec, pixelSize: descriptor.pixelSize, frameRate: frameRate)

            try await begin(
                engine: engine,
                request: .stream(filter: plan.filter, configuration: configuration),
                encoder: encoder,
                source: source
            )
            pipelineLog.notice("capturing \(descriptor.title, privacy: .public)")

        case .synthetic(let engine):
            if frameRate != engine.frameRate {
                pipelineLog.notice("""
                    synthetic pipeline was built for \(engine.frameRate, privacy: .public) fps; \
                    the \(frameRate, privacy: .public) fps asked for here is ignored
                    """)
            }
            let encoder = try VideoEncoder(
                codec: codec,
                pixelSize: engine.pixelSize,
                frameRate: engine.frameRate
            )

            try await begin(engine: engine, request: .synthetic, encoder: encoder, source: source)
            pipelineLog.notice("""
                generating \(Int(engine.pixelSize.width), privacy: .public)×\
                \(Int(engine.pixelSize.height), privacy: .public) frames \
                @ \(engine.frameRate, privacy: .public) fps
                """)
        }
    }

    /// Wires a source and an encoder to each other and starts the source.
    ///
    /// Shared by both backends, so neither can drift from the other's ordering. The order
    /// matters at two points: the callbacks are attached before the source is started, or
    /// the first frames of a session have nowhere to go; and the keyframe is asked for
    /// after it, because a request made before there is a session to make it on is lost —
    /// the first frame of a session must be a keyframe, since a client joining mid-stream
    /// has no parameter sets and nothing to decode against.
    private func begin(
        engine: any CaptureFrameSource,
        request: CaptureStartRequest,
        encoder: VideoEncoder,
        source: CaptureSource
    ) async throws {
        // Copyable because a `let` existential's settable properties cannot be assigned to,
        // even when every conforming type is a class.
        var engine = engine

        lock.withLock {
            self.source = source
            self.encoder = encoder
            self.awaitsKeyframe = true
        }
        encoder.onFrame = { [weak self] encoded in self?.deliver(encoded) }
        encoder.onFailure = { [weak self] error in self?.report(error) }

        engine.onFrame = { [weak self] frame in self?.ingest(frame) }
        engine.onStop = { [weak self] error in self?.report(error) }

        do {
            try await engine.start(request)
        } catch {
            await stop()
            throw error
        }

        encoder.requestKeyframe()
    }

    func stop() async {
        await engine.stop()
        let encoder = lock.withLock { () -> VideoEncoder? in
            let current = self.encoder
            self.encoder = nil
            self.source = nil
            self.awaitsKeyframe = false
            return current
        }
        encoder?.shutdown()
    }

    /// Forces the next frame to be a keyframe, whenever that frame arrives.
    ///
    /// This is what a new client connection calls. It does not wait for the two-second
    /// keyframe interval, and it does not tear the session down to get one.
    func requestKeyframe() {
        let encoder = lock.withLock { () -> VideoEncoder? in
            awaitsKeyframe = true
            return self.encoder
        }
        encoder?.requestKeyframe()
    }

    /// Changes the bitrate on the running encoder. Also arms a keyframe request so the new
    /// rate takes effect quickly rather than waiting for the two-second interval.
    func setBitrate(_ bitsPerSecond: Int) {
        let encoder = lock.withLock { self.encoder }
        encoder?.setBitrate(bitsPerSecond)
        encoder?.requestKeyframe()
    }

    // MARK: - Frame flow

    /// A captured frame, on the capture queue.
    private func ingest(_ frame: CapturedFrame) {
        onGeometry?(frame.geometry)

        // The stream's surface changes size when a captured window is resized — the stream
        // keeps producing frames at the new size, but the session was created for the old
        // one and cannot encode a frame of a different size at all. Rebuilding is the only
        // option, and it costs the client a keyframe, so it happens on the size *changing*
        // rather than on every frame.
        let size = VideoEncoder.encodedSize(
            for: CGSize(
                width: CVPixelBufferGetWidth(frame.pixelBuffer),
                height: CVPixelBufferGetHeight(frame.pixelBuffer)
            )
        )

        let encoder: VideoEncoder
        let current = lock.withLock { self.encoder }
        if let current, current.pixelSize == size {
            encoder = current
        } else {
            do {
                encoder = try rebuildEncoder(for: size, replacing: current)
            } catch {
                report(error as? CaptureError ?? .encodingFailed("\(error)"))
                return
            }
        }

        do {
            try encoder.encode(frame)
        } catch {
            report(error as? CaptureError ?? .encodingFailed("\(error)"))
        }
    }

    /// Must be called on the capture queue, where it is the only writer.
    private func rebuildEncoder(for size: CGSize, replacing current: VideoEncoder?) throws -> VideoEncoder {
        let replacement = try VideoEncoder(
            codec: codec,
            pixelSize: size,
            frameRate: current?.frameRate ?? 60
        )
        replacement.onFrame = { [weak self] encoded in self?.deliver(encoded) }
        replacement.onFailure = { [weak self] error in self?.report(error) }

        // A new session has no keyframe that a decoder following the old one can use, so one
        // is owed whether or not the session asked for it.
        lock.withLock {
            encoder = replacement
            awaitsKeyframe = true
        }
        // Shut down only after the swap, so nothing can hand a frame to a dead session.
        current?.shutdown()

        pipelineLog.notice("""
            capture surface resized to \(Int(size.width), privacy: .public)×\
            \(Int(size.height), privacy: .public) · encoder rebuilt
            """)
        return replacement
    }

    /// An encoded frame, on VideoToolbox's thread.
    private func deliver(_ encoded: EncodedFrame) {
        if encoded.isKeyframe {
            lock.withLock { awaitsKeyframe = false }
        }
        let consumer = lock.withLock { _onFrame }
        consumer?(encoded)
    }

    /// Hands a failure to the session, on whatever thread produced it.
    ///
    /// A stream that stopped is not torn down here. The session decides: sleeping and waking
    /// should restart the stream, while a revoked permission should put an explanation on
    /// screen, and only the session knows which one it is looking at.
    private func report(_ error: CaptureError) {
        let failure = lock.withLock { _onFailure }
        failure?(error)
    }
}
