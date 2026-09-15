import CoreGraphics
import CoreMedia
import CoreVideo
import Foundation
import RemoteCore
import os

private let overlayLog = Logger(subsystem: "pl.dmq.peering.host", category: "capture")

/// A larger pointer, drawn into the picture because the system will not draw one.
///
/// ScreenCaptureKit's only controls over the cursor are switches: `showsCursor` shows or hides
/// the system's own pointer, `showMouseClicks` draws a ring around a click, and neither has a
/// size beside it. So the pointer a frame carries is always the one on the Mac, about sixteen
/// points tall, and that picture is the whole display — 1512×982 points on a built-in panel,
/// which the client draws in roughly 390. A factor of four puts the pointer at something like
/// four points on a phone, which is the complaint this answers, and the only way to answer it
/// is to have the stream leave the cursor out and put a bigger one back.
///
/// **The luma plane and nothing else.** Frames arrive as `420v`, bi-planar video-range YCbCr,
/// and a pointer has no colour in it: the system's own is white with a black edge, and two
/// shades are all that takes. Writing Y alone is one pass over a few hundred rows, with no
/// colour conversion, no second pixel format, and no work on the chroma plane at all. The two
/// values are 16 and 235 rather than 0 and 255, which matters more than it looks: this is
/// video range, where 0 and 255 lie outside what the encoder is told to expect, and
/// out-of-range luma is not clamped on the way through — it comes back as a crushed edge or a
/// ring around the pointer.
///
/// **Aliased on purpose.** Every edge is a hard step between those two values. At several
/// times the size of the system's pointer the steps stop being visible, and the alternative is
/// a coverage calculation per pixel on a path that runs sixty times a second.
///
/// **Nothing here allocates per frame.** The shape is a polygon in the pointer's own units —
/// tip at the origin, one unit tall — built once at construction, and a frame's size only ever
/// multiplies it. The rasteriser's scratch is a fixed array it reuses. The one object a frame
/// does produce is the `CGEvent` the pointer's position is read from, which is the only way
/// the window server is asked where the cursor is.
///
/// The system pointer deliberately remains enabled in ScreenCaptureKit underneath this one.
/// Its movement makes the stream produce real consecutive frames even on a quiet desktop;
/// this larger opaque shape covers it at the same tip in the frame sent to the phone.
///
/// The synthetic pipeline cannot use this and does not try: generated frames describe no
/// screen, so there is no coordinate space for a pointer to be placed in. See
/// ``CapturePipeline/ingest(_:)``.
final class CursorOverlay: @unchecked Sendable {
    /// How much larger than the system's own pointer the drawn one is.
    ///
    /// A size in points would be no use: the client scales the picture to its own screen, and
    /// a point is not a fixed share of a picture whose size follows the display it came from.
    /// A fraction of the frame's height is, and it survives a source switch as well — the
    /// pointer keeps its share of the picture however large the picture is.
    enum Size: String, CaseIterable, Sendable {
        case small
        case medium
        case large

        /// The pointer's height, as a fraction of the frame's height.
        ///
        /// The system's arrow is about sixteen points on a display around a thousand points
        /// tall, so it takes up a little over one and a half percent of the height. Each case
        /// here is a multiple of that, which is the honest way to describe them: this pointer
        /// is two to four times the size of the one the Mac is showing.
        var fractionOfHeight: CGFloat {
            switch self {
            case .small: return 0.032   // roughly twice the system's pointer
            case .medium: return 0.048  // roughly three times
            case .large: return 0.064   // roughly four times
            }
        }
    }

    /// The two values a pointer is drawn with, in video range.
    private static let ink: UInt8 = 235
    private static let edge: UInt8 = 16

    /// The drawn pointer's edge, as a fraction of its own height.
    ///
    /// Half of it is stroked outside the outline and half of it ends up under the fill, so the
    /// edge that shows is thinner than this number. It scales with the pointer rather than
    /// being a fixed number of pixels, because what an edge is for is separating the pointer
    /// from whatever is behind it, and that is the one thing that fails if the edge is a
    /// hairline under a pointer drawn four times the size of the system's.
    private static let edgeWidth: CGFloat = 0.09

    /// The pointer's outline: tip at the origin, y down, in units of its own height.
    ///
    /// A polygon rather than a bitmap of the system's cursor, because a bitmap is what cannot
    /// be made bigger: the cursor art is sixteen pixels with one-pixel steps in its edges, and
    /// scaling it up is a pointer four times the size with the same number of steps, which
    /// looks like a staircase. These are the classic proportions — the vertical left edge, the
    /// notch where the tail leaves the head, and the tail's foot.
    private static let outline: [CGPoint] = [
        CGPoint(x: 0.000, y: 0.000),  // the tip, which is where the pointer is
        CGPoint(x: 0.000, y: 0.707),  // down the left edge, which is vertical
        CGPoint(x: 0.201, y: 0.512),  // up into the notch between the head and the tail
        CGPoint(x: 0.390, y: 0.963),  // down the tail's left side to its foot
        CGPoint(x: 0.549, y: 0.896),  // across the foot
        CGPoint(x: 0.360, y: 0.445),  // back up the tail's right side
        CGPoint(x: 0.622, y: 0.445),  // out to the head's bottom right corner
    ]

    /// One polygon to fill, and what to fill it with.
    private struct Pass {
        let range: Range<Int>
        let value: UInt8
    }

    private let lock = NSLock()

    /// The polygons, in the pointer's own units, each closed by repeating its first point so
    /// that the rasteriser never has to wrap an index around the end of a range.
    ///
    /// The edge quads come first and the outline last, which is the whole of the drawing
    /// order: the fill goes over the inner half of its own edge and leaves the outer half
    /// showing.
    private let vertices: [CGPoint]
    private let passes: [Pass]

    /// Where a scanline's crossings are collected. A pointer's polygon crosses a row at most
    /// seven times, so this is never close to full — it is a fixed array rather than one per
    /// call because a frame draws eight polygons and this runs at sixty frames a second.
    private var intersections = [CGFloat](repeating: 0, count: 16)

    /// Whether a refusal has been logged yet. See ``report(_:)``.
    private var reportedRefusal = false

    /// Where the pointer's tip was last drawn into a frame, to the nearest pixel of the
    /// picture.
    ///
    /// Nil whenever no frame carries a pointer: the overlay is off, or the pointer has been
    /// somewhere other than over the captured content since the last frame. An idle sample is
    /// only worth a frame of its own when the tip is not here now — the client is already
    /// looking at a picture with the pointer in this spot, and a pointer that has shifted by
    /// a fraction of a pixel draws the same arrow again.
    private var drawnTip: CGPoint?

    /// Where the last frame that carried a picture said its content sits on screen.
    ///
    /// Kept because an idle sample does not have to say, and the pointer has to be placed
    /// somewhere. The screen has not changed since that frame — that is what an idle sample
    /// means — so the answer from then is still the answer now, and a better one than
    /// nothing. See ``redraw(_:)``.
    private var lastTransform: InputTransform?

    /// The picture, and the buffers idle frames are drawn into. Nil until the first frame
    /// the stream delivers. See ``Scratch``.
    private var scratch: Scratch?

    private var enabled: Bool
    private var chosenSize: Size

    init(isEnabled: Bool = true, size: Size = .medium) {
        self.enabled = isEnabled
        self.chosenSize = size
        (self.vertices, self.passes) = Self.shape()
    }

    /// Whether a pointer is drawn at all. Off returns every frame exactly as it arrived.
    var isEnabled: Bool {
        get { lock.withLock { enabled } }
        set { lock.withLock { enabled = newValue } }
    }

    var size: Size {
        get { lock.withLock { chosenSize } }
        set { lock.withLock { chosenSize = newValue } }
    }

    // MARK: - Drawing

    /// Draws the pointer into a frame, or leaves the frame exactly as it arrived.
    ///
    /// **There are more ways not to draw than to draw, and every one of them returns without
    /// touching the frame.** The overlay is off; the pointer is not over the captured content;
    /// the frame does not say where its content sits on screen; the buffer is not the pixel
    /// format this understands; the plane cannot be locked. A frame that is late, wrong, or
    /// half-drawn is worse than a pointer that is where the system would have put it, so
    /// nothing here throws, retries, or writes a byte until every question above has an
    /// answer.
    ///
    /// Called on the capture queue, where it is the only thread drawing. The lock it takes is
    /// held for the draw as well as for the setting, and that is deliberate: the sizes and the
    /// scratch are this object's, and the only other caller is a preference changing on the
    /// main actor, which can wait a few hundred microseconds for one frame.
    func draw(into buffer: CVPixelBuffer, geometry: FrameGeometry) {
        // Whatever pointer this call manages to draw is the one the client will be looking
        // at, so the record of what an idle frame would have to undo starts empty and is
        // filled in only if the pointer lands.
        //
        // The high-water mark for the timeline goes with it. A stream that has restarted
        // begins again at a frame of its own, and the clock it reports from then on has no
        // relation to the one before — holding the old mark would refuse every idle frame
        // from here on. Dropping it is safe because a frame of the stream's own is what
        // establishes the timeline, and everything the overlay submits after it is derived
        // from the same clock the stream is running on.
        guard lock.withLock({ () -> Bool in
            drawnTip = nil
            scratch?.lastSentTime = .invalid
            return enabled
        }) else { return }

        // The format is checked exactly, rather than trusting that the configuration still
        // sets it. A buffer in another format has a different idea of what plane 0 is — in
        // `BGRA` it is the whole picture, one byte per channel — and writing luma into it is
        // how a band of colour appears across the middle of a frame.
        guard CVPixelBufferIsPlanar(buffer),
              CVPixelBufferGetPlaneCount(buffer) > 1,
              CVPixelBufferGetPixelFormatType(buffer) == kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange
        else {
            report("the frame is not in the pixel format this draws into")
            return
        }

        guard CVPixelBufferLockBaseAddress(buffer, []) == kCVReturnSuccess else {
            report("the frame's pixels could not be locked")
            return
        }
        defer { CVPixelBufferUnlockBaseAddress(buffer, []) }

        guard let base = CVPixelBufferGetBaseAddressOfPlane(buffer, 0),
              CVPixelBufferGetBaseAddressOfPlane(buffer, 1) != nil
        else {
            report("the frame has no planes this can read")
            return
        }
        let plane = base.assumingMemoryBound(to: UInt8.self)
        let stride = CVPixelBufferGetBytesPerRowOfPlane(buffer, 0)
        let width = CVPixelBufferGetWidthOfPlane(buffer, 0)
        let height = CVPixelBufferGetHeightOfPlane(buffer, 0)
        guard width > 0, height > 0, stride >= width else {
            report("the frame's luma plane has no usable size")
            return
        }

        // **Before a pointer is drawn into it, and before the pointer's position is even
        // read.** This frame is the picture an idle frame will be built on, and this is the
        // last moment it is in hand and still free of a pointer — the overlay's copy has to
        // be of the screen, not of the screen with an arrow in it. It happens ahead of the
        // pointer guards below on purpose: a picture the overlay has none of is no use the
        // moment the pointer comes back over the content, and there is no second chance at
        // one until the stream delivers another frame.
        refresh(from: buffer, geometry: geometry)

        // The pointer, in the global point space frames describe their content in — the same
        // call, and the same space, `InputTransform` posts events into, so no axis has to be
        // flipped. Nil is not expected and not worth drawing through: a pointer at the last
        // known position is a wrong pointer, and the position is the one thing about it that
        // has to be right.
        guard let pointer = CGEvent(source: nil)?.location else {
            report("the pointer's position could not be read")
            return
        }

        // Where the pointer is *in the picture*, by inverting the mapping the client's own
        // input goes through — the same `InputTransform` the host built from this frame's
        // geometry. That is the point of doing it this way rather than by mapping through the
        // content rect: whatever the client does with a tap lands where this draws, so the
        // pointer and the taps cannot drift apart.
        guard let transform = geometry.inputTransform else {
            report("the frame does not say where its content sits on screen")
            return
        }
        lock.withLock { lastTransform = transform }

        let position = transform.normalizedPoint(fromGlobal: pointer)
        // Outside `0…1` is the pointer being on another display, or beside a captured window,
        // and is the ordinary case rather than a failure: there is no pointer over the
        // content because the pointer is not over the content.
        guard position.x >= 0, position.x <= 1, position.y >= 0, position.y <= 1 else { return }

        let size = lock.withLock { chosenSize }
        // The luma plane's own dimensions rather than the frame's. For `420v` they are the
        // same picture, since luma is the plane that is not subsampled, and it is the plane
        // that has a stride: its height is what the pointer is sized against and its width is
        // what a row of it can hold.
        let scale = CGFloat(height) * size.fractionOfHeight
        guard scale.isFinite, scale >= 1 else {
            report("the frame is too small for a pointer to be drawn at any size")
            return
        }

        let tip = CGPoint(x: position.x * CGFloat(width), y: position.y * CGFloat(height))

        lock.withLock {
            for pass in passes {
                rasterize(
                    pass,
                    tip: tip,
                    scale: scale,
                    plane: plane,
                    stride: stride,
                    width: width,
                    height: height
                )
            }
            // Recorded only once the pointer is in the picture, and to the same pixel the
            // tip was placed at. Every path above that returned early left this nil, which
            // is the honest answer: no frame carries a pointer at this spot.
            drawnTip = CGPoint(x: tip.x.rounded(), y: tip.y.rounded())
        }
    }

    // MARK: - Idle frames

    /// A frame made out of an idle sample and the pointer's own movement, or `nil` when there
    /// is nothing to send.
    ///
    /// **Why a frame has to be made at all.** ScreenCaptureKit reports `.idle` when the
    /// display's content has not changed. This was built for the former configuration that
    /// hid the system pointer, where pointer movement could not make a real frame. Production
    /// capture now keeps that pointer visible and this fallback remains disabled in
    /// ``CapturePipeline`` because invented frames broke the decoder's reference chain.
    ///
    /// **The sample supplies no pixels, and that is deliberate.** An idle sample is not a
    /// frame and cannot be treated as one: it may carry no image buffer at all, and a host
    /// that waits for one waits forever on exactly the screens this path exists for — which
    /// is what happened, and what put a measured ceiling of ten to fifteen frames a second on
    /// a pointer that was moving over a still screen. All it is asked for is that the screen
    /// has not changed and, if it is saying, where the content sits on it. The picture is
    /// this object's own, kept while a frame the stream actually delivered was in hand — see
    /// ``Scratch`` and ``refresh(from:geometry:)``. ``CaptureEngine`` forwards idle samples
    /// without so much as looking at their buffers, so nothing here can come to depend on
    /// one again.
    ///
    /// **Where the frame is built, and why it is not the last one delivered.** The buffer
    /// that arrived with the last frame belongs to a pool ScreenCaptureKit reuses and is
    /// still being read by VideoToolbox, so drawing into it is drawing into a frame the
    /// encoder may be part-way through — which is not a choppy pointer, it is a torn or
    /// garbled picture on the phone, and that is the outcome that must not be possible.
    /// Everything below is written into a buffer this object owns, and the only question
    /// left is whether the encoder has finished with it. ``acquire(_:)`` answers that
    /// question rather than assuming it.
    ///
    /// **What gets copied, and what it costs.** Two rectangles the size of the pointer: the
    /// pixels under the pointer being replaced, and the pixels under the pointer being
    /// drawn. Everything between them is the same picture it was, because that is what an
    /// idle sample *means* — so on a screen that is not changing, one frame in a run pays
    /// for the picture and every one after it costs two pointer-sized rectangles.
    ///
    /// A frame pays for the picture again when the screen changed under it, because there is
    /// no way to know which pixels did and copying all of them is the only correct answer.
    /// That is bounded by how often the screen changes, and the bound is enforced rather
    /// than hoped for: a delivered frame closes this path for one sample, so a screen
    /// changing at half the stream's rate produces no idle frames at all — its own frames
    /// are already carrying the pointer at that rate — and the cost only appears on screens
    /// slow enough for the idle frames to be worth having. Measured on a model of this path
    /// driving a real encoder: a still screen with the pointer moving sends 119 frames in
    /// two seconds for one whole-picture copy, a screen changing ten times a second sends
    /// forty a second for twenty copies, and one changing thirty times a second sends none
    /// and copies nothing.
    func redraw(_ sample: IdleSample) -> CapturedFrame? {
        guard lock.withLock({ enabled }) else { return nil }

        // The same question ``draw(into:geometry:)`` asks, with the answer the last frame
        // gave standing in when this sample does not have one. Nothing about an idle sample
        // requires it to describe the content, and the screen has not changed since a frame
        // that did — so the last good answer is still the right answer, and it is the only
        // one there is. Nil only while no frame has ever said, which is the one case where a
        // pointer has no place to be.
        guard let transform = lock.withLock({ sample.geometry.inputTransform ?? lastTransform }) else {
            return nil
        }

        guard let pointer = CGEvent(source: nil)?.location else {
            report("the pointer's position could not be read")
            return nil
        }
        let position = transform.normalizedPoint(fromGlobal: pointer)
        guard position.x >= 0, position.x <= 1, position.y >= 0, position.y <= 1 else { return nil }

        // Everything past this point is built from the scratch, and the scratch is built
        // from the frame size — which comes from the picture the overlay kept, not from this
        // sample, which has nothing to measure.
        var refusal: String?
        let frame = lock.withLock { () -> CapturedFrame? in
            guard var scratch = self.scratch, scratch.holdsPicture else { return nil }

            // The stream's own frame interval where it reports one, because that is what
            // keeps the stand-in timestamps running at the rate the stream is running at.
            if sample.duration.isValid, sample.duration.value > 0 {
                scratch.lastInterval = sample.duration
            }
            guard let time = Self.timestamp(
                reported: sample.presentationTime,
                after: scratch.lastSentTime,
                interval: scratch.lastInterval
            ) else {
                return nil
            }
            scratch.lastSentTime = time

            let width = scratch.width
            let height = scratch.height
            let size = chosenSize
            let scale = CGFloat(height) * size.fractionOfHeight
            guard scale.isFinite, scale >= 1 else { return nil }

            // Nothing has moved, so there is nothing to send. An idle sample arrives on
            // schedule whether or not anything happened, and a frame drawn from one where
            // the pointer is where it already was is a frame the client is already looking
            // at — an entire stream of identical frames, which is the waste idle detection
            // exists to prevent.
            //
            // This is also the rate limit, and it is the right one: samples are delivered no
            // faster than the stream's frame interval, so one frame per sample is the
            // stream's own rate, and ``acquire(_:)`` caps it further at whatever the encoder
            // can take.
            let tip = CGPoint(
                x: (position.x * Double(width)).rounded(),
                y: (position.y * Double(height)).rounded()
            )
            guard tip != drawnTip else { return nil }

            // **An idle frame is only worth sending when the screen has just been still.**
            // A screen that is changing is already carrying the pointer in the frames it is
            // producing, at whatever rate it is producing them, so an idle frame between two
            // of those adds nothing a client can see — while costing a whole-picture copy,
            // because the picture it would be built on has just changed. On a screen that
            // changes every other sample that is a copy for every idle frame and no visible
            // gain at all; measured, not supposed. Refusing the first one after a delivered
            // frame costs one sample out of a run of sixty on a screen that has stopped
            // changing, and nothing at all on one that never changed, where there is no
            // delivered frame to be after.
            //
            // It is checked here rather than at the top because it is the copy it is
            // avoiding, and a sample that was not going to produce a frame was never going
            // to make one.
            if scratch.pictureArrived {
                scratch.pictureArrived = false
                self.scratch = scratch
                return nil
            }
            scratch.pictureArrived = false

            guard let region = Self.region(bounds(tip: tip, scale: scale), width: width, height: height),
                  region.width <= scratch.patchWidth, region.height <= scratch.patchHeight
            else {
                refusal = "the pointer is larger than the region kept for taking it back out"
                return nil
            }

            guard let buffer = acquire(scratch) else { return nil }
            guard CVPixelBufferLockBaseAddress(buffer, []) == kCVReturnSuccess else { return nil }
            defer { CVPixelBufferUnlockBaseAddress(buffer, []) }

            guard let destinationBase = CVPixelBufferGetBaseAddressOfPlane(buffer, 0) else {
                refusal = "the buffer set aside for idle frames has no luma plane to write"
                return nil
            }
            let destination = destinationBase.assumingMemoryBound(to: UInt8.self)
            let destinationStride = CVPixelBufferGetBytesPerRowOfPlane(buffer, 0)
            guard destinationStride >= width, CVPixelBufferGetHeightOfPlane(buffer, 0) == height else {
                refusal = "the buffer set aside for idle frames is not the size of the frame"
                return nil
            }

            // Which of the pool's buffers this is, by where it keeps its luma plane — that
            // does not move for as long as the surface under it exists, and the pool holds
            // its surfaces because they are told not to age out. See
            // ``makeScratch(width:height:geometry:)``. One it has never handed over before is
            // one whose contents are nobody's, and the record it gets starts out knowing
            // nothing.
            if scratch.buffers.count >= Scratch.bufferLimit { scratch.buffers.removeAll() }
            let index = scratch.buffers.firstIndex { $0.planeBase == destinationBase }
            var state: Scratch.Buffer
            if let index {
                state = scratch.buffers[index]
            } else {
                state = Scratch.Buffer(
                    planeBase: destinationBase,
                    stride: destinationStride,
                    patch: [UInt8](repeating: 0, count: scratch.patchWidth * scratch.patchHeight),
                    patchRegion: nil,
                    generation: 0
                )
            }

            // A buffer whose rows are not the ones the saved region was taken at cannot have
            // that region put back into it — the rows would land in the wrong places — so the
            // whole picture goes in and the region is forgotten.
            if state.stride != destinationStride {
                state.patchRegion = nil
                state.generation = 0
                state.stride = destinationStride
            }

            // A buffer holding an older picture is one the picture has to be copied into
            // whole: it is the only way the pixels outside the pointer can be brought up to
            // date, because nothing here knows which of them changed. It happens once per
            // buffer per frame the screen actually changed on, and never at all on the still
            // screen this path is for. **The saved region goes with it** — it holds the
            // pointer's rectangle as the *old* picture had it, and putting that back after
            // copying the new one in would stamp a rectangle of the previous screen over it,
            // which is a smudge rather than a pointer.
            if state.generation != scratch.generation {
                guard Self.copyPicture(from: scratch.picture, into: buffer) else { return nil }
                state.patchRegion = nil
                state.generation = scratch.generation
            }
            // The pointer that is in this buffer is the only thing in it that is not the
            // picture, so putting the saved pixels back is the whole of removing it.
            if let previous = state.patchRegion {
                restore(previous, from: state.patch, into: destination, stride: destinationStride)
                state.patchRegion = nil
            }

            save(region, from: destination, stride: destinationStride, into: &state.patch)
            state.patchRegion = region

            if let index {
                scratch.buffers[index] = state
            } else {
                scratch.buffers.append(state)
            }

            for pass in passes {
                rasterize(
                    pass,
                    tip: tip,
                    scale: scale,
                    plane: destination,
                    stride: destinationStride,
                    width: width,
                    height: height
                )
            }

            self.scratch = scratch
            drawnTip = tip

            return CapturedFrame(
                pixelBuffer: buffer,
                presentationTime: time,
                duration: sample.duration,
                geometry: scratch.geometry
            )
        }

        if let refusal { report(refusal) }
        return frame
    }

    /// When to say an idle frame was taken, or nil when no honest answer is available.
    ///
    /// **Strictly forward, by construction, whatever the stream says.** VideoToolbox requires
    /// a timeline that moves forward, and a frame submitted with a timestamp it has already
    /// seen is an error rather than a dropped frame — the whole stream failing rather than
    /// one pointer step being late. An idle sample is not a frame and nothing requires it to
    /// carry a usable time: it may have none at all, and one that has one may be repeating
    /// the timestamp of the frame it is a copy of, which is a duplicate rather than an
    /// advance and is just as fatal. So the sample's answer is taken when it is genuinely
    /// ahead, and otherwise the stream's own frame interval is added to the last frame sent.
    ///
    /// That makes the stand-in run at the stream's rate rather than at whatever this call
    /// cost, and it means a pointer moving over a still screen advances the timeline at
    /// exactly the rate the client is being served at.
    private static func timestamp(reported: CMTime, after last: CMTime, interval: CMTime) -> CMTime? {
        let step = interval.isValid && interval.value > 0
            ? interval
            : CMTime(value: 1, timescale: 60)

        let candidate: CMTime
        if reported.isValid, reported.isNumeric {
            candidate = reported
        } else if last.isValid {
            candidate = CMTimeAdd(last, step)
        } else {
            // Neither the sample nor a previous frame has an answer. The host clock is the
            // clock ScreenCaptureKit timestamps frames from, so this lands in the same
            // timeline the stream is already on rather than in a second one beside it.
            candidate = CMClockGetTime(CMClockGetHostTimeClock())
        }

        guard candidate.isValid, candidate.isNumeric else { return nil }
        guard last.isValid, candidate <= last else { return candidate }
        return CMTimeAdd(last, step)
    }

    /// A rectangle of the luma plane, in pixels.
    private struct Region {
        let x: Int
        let y: Int
        let width: Int
        let height: Int
    }

    /// The buffers idle frames are built in, and what is needed to bring one up to date by
    /// copying the pixels that changed rather than the whole picture.
    ///
    /// **Why there are buffers of this object's own.** The frame the stream last delivered
    /// cannot be drawn into — see ``redraw(_:)`` — so the picture has to live somewhere
    /// this object controls, and it has to survive being handed to the encoder, which holds
    /// on to it. What makes that safe is the pool: it only ever hands over a buffer nothing
    /// else is holding, and asking for one is therefore the same question as "has the
    /// encoder finished with this". See ``acquire(_:)``.
    ///
    /// **Why it is more than one, and why each keeps its own record.** VideoToolbox keeps
    /// the frame it was given until the next one is encoded, because that is the reference
    /// the next frame is coded against, so the buffer handed over is not always the buffer
    /// that comes back. At the stream's own rate one is enough — measured against a running
    /// encoder, a buffer handed over every sixteenth of a second is released again well
    /// before the next is asked for — but idle frames are not evenly spaced: the pointer
    /// stops and starts, and a buffer handed over just before it stopped stays with the
    /// encoder until something else is submitted. A pool of one would then have nothing left
    /// to give and the pointer would stop moving. The threshold lets a second buffer be made
    /// for exactly that case, and each buffer carries a pointer drawn at the place it was
    /// last used, so undoing that pointer means knowing where it was and what was underneath
    /// it, which is different for each.
    ///
    /// **Why this is not a full copy per frame.** An idle sample means the picture has not
    /// changed, so between one idle frame and the next the only pixels that are different
    /// are the ones under the pointer. Each buffer keeps those — the pixels the pointer is
    /// drawn over, saved before it is drawn — and putting them back is the whole of undoing
    /// the last pointer. The picture is only ever copied whole when it is not the same
    /// picture any more, which is when the stream delivers a frame rather than an idle
    /// sample; on a screen quiet enough to need this path at all, that is once.
    /// **What keeps the picture.** An idle sample has no pixels to give — see ``IdleSample``
    /// — so the picture an idle frame is drawn on has to be one this object kept, and the
    /// only moment it can be kept is here: the stream's own frames, copied before a pointer
    /// is drawn into them.
    private struct Scratch {
        /// The picture, with no pointer in it, as of the last frame the stream delivered.
        ///
        /// A buffer of this object's alone, never handed to the encoder and never wrapped in
        /// a pool, so there is no question about when it is safe to write: it is always
        /// safe, because nothing else has ever been given it. It is what ``pictureGeneration``
        /// counts, and the pool's buffers are compared against that to know whether they
        /// still hold the screen.
        let picture: CVPixelBuffer
        /// Bumped every time ``picture`` is rewritten. A pool buffer holding a different
        /// number is holding a screen the client has already moved on from.
        var generation: UInt64
        /// Whether ``picture`` has been written at all. Until it has, an idle frame would be
        /// drawn on whatever a fresh CoreVideo buffer happens to contain, which is nothing
        /// this object put there.
        var holdsPicture: Bool
        /// Whether a frame has been delivered since the last idle sample, which is what says
        /// the screen is not still and an idle frame would earn nothing. See ``redraw(_:)``.
        var pictureArrived: Bool

        /// The pool the frames handed to the encoder come from.
        let pool: CVPixelBufferPool
        let width: Int
        let height: Int
        /// Where the content sat on screen in the frame the picture was copied from. An idle
        /// sample may not say, and the answer cannot have changed since — the screen has not.
        var geometry: FrameGeometry
        /// The timestamp of the last frame sent from here, and the stream's own frame
        /// interval, both for placing the next one on the timeline. See ``timestamp(reported:duration:after:interval:)``.
        var lastSentTime: CMTime
        var lastInterval: CMTime
        /// The room kept, in every buffer, for the pixels under the pointer. The pointer's
        /// size is a preference and can change while the stream is running, so the room is
        /// kept for the largest it can be set to rather than for the one in force now.
        let patchWidth: Int
        let patchHeight: Int
        /// What is known about each buffer the pool has handed over.
        var buffers: [Buffer]

        /// A ceiling on ``buffers``, which the pool's own threshold already keeps it under.
        /// It is here so that a pool handing back more than it was told to cannot grow this
        /// without bound; all it costs when it trips is a picture copied whole into buffers
        /// whose records were forgotten.
        static let bufferLimit = 4

        /// One buffer of the pool's, as this object last left it.
        struct Buffer {
            /// Where the buffer keeps its luma plane. How a buffer is recognised across
            /// acquisitions, since what the pool hands back is a surface and not an object.
            let planeBase: UnsafeMutableRawPointer
            var stride: Int
            /// The pixels the pointer covers, packed at the region's own width.
            var patch: [UInt8]
            /// Where in the plane ``patch`` belongs, or nil when no pointer is drawn in
            /// this buffer. The region and the patch go together: one without the other is
            /// a rectangle of picture put back over a pointer that was never there.
            var patchRegion: Region?
            /// Which picture of this object's is in the buffer — see ``Scratch/generation``.
            /// A different number means the pixels outside the pointer are an older screen.
            var generation: UInt64
        }
    }

    /// A buffer out of the pool, or nil when the encoder still has them all.
    ///
    /// **This call is the whole answer to "is it safe to write into".** The threshold caps
    /// the pool at ``Scratch/bufferLimit`` buffers, and a pool only ever hands over one that
    /// nothing else holds — so there are exactly two answers: a buffer that is this object's
    /// alone, or `kCVReturnWouldExceedAllocationThreshold`, which means every buffer is still
    /// with the encoder and this sample is dropped. Nothing here writes into a buffer the
    /// encoder may be reading, and nothing here has to guess when the encoder is done with
    /// one. The cost of the guarantee is that idle frames go out no faster than the encoder
    /// retires them, which is not a compromise: a frame the encoder cannot take is a frame
    /// nobody was going to see.
    private func acquire(_ scratch: Scratch) -> CVPixelBuffer? {
        var buffer: CVPixelBuffer?
        let status = CVPixelBufferPoolCreatePixelBufferWithAuxAttributes(
            kCFAllocatorDefault,
            scratch.pool,
            [kCVPixelBufferPoolAllocationThresholdKey: Scratch.bufferLimit] as CFDictionary,
            &buffer
        )
        guard status == kCVReturnSuccess else { return nil }
        return buffer
    }

    /// The place the picture is kept, made for a frame of this size and made again if the
    /// stream's surface changes size underneath it.
    ///
    /// Must be called with the lock held, on the capture queue, which is the only thread that
    /// touches the scratch.
    private func makeScratch(width: Int, height: Int, geometry: FrameGeometry) -> Scratch? {
        // Room for the largest the pointer can be set to. Measured from the shape itself
        // rather than written down as a number, so that changing the outline cannot quietly
        // leave the patch too small to take a pointer back out.
        let box = bounds(tip: .zero, scale: CGFloat(height) * Size.large.fractionOfHeight)
        let patchWidth = Int(box.width.rounded(.up)) + 2
        let patchHeight = Int(box.height.rounded(.up)) + 2
        guard patchWidth > 0, patchHeight > 0 else { return nil }

        let bufferAttributes: [CFString: Any] = [
            kCVPixelBufferPixelFormatTypeKey: kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange,
            kCVPixelBufferWidthKey: width,
            kCVPixelBufferHeightKey: height,
            kCVPixelBufferIOSurfacePropertiesKey: [:] as CFDictionary,
        ]

        // The picture is made plainly rather than out of the pool. It is never handed to
        // anyone — that is the whole point of it — so it needs none of what the pool is for,
        // and giving it to the pool would put it at the mercy of an allocation threshold.
        var picture: CVPixelBuffer?
        guard CVPixelBufferCreate(
            kCFAllocatorDefault,
            width,
            height,
            kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange,
            bufferAttributes as CFDictionary,
            &picture
        ) == kCVReturnSuccess, let picture else { return nil }

        let poolAttributes: [CFString: Any] = [
            // A pool buffer ages out after a second by default, and this one goes unused for
            // exactly as long as the screen takes to change — which on a screen quiet enough
            // to need this path is most of the time. A buffer that had aged out would come
            // back as a surface with nothing of this object's in it, and the pointer would
            // be drawn over whatever happened to be left there.
            kCVPixelBufferPoolMaximumBufferAgeKey: 0,
        ]

        var pool: CVPixelBufferPool?
        guard CVPixelBufferPoolCreate(
            kCFAllocatorDefault,
            poolAttributes as CFDictionary,
            bufferAttributes as CFDictionary,
            &pool
        ) == kCVReturnSuccess, let pool else { return nil }

        return Scratch(
            picture: picture,
            // Nothing has been copied into it yet, so no pool buffer can be holding it.
            generation: 0,
            holdsPicture: false,
            pictureArrived: true,
            pool: pool,
            width: width,
            height: height,
            geometry: geometry,
            lastSentTime: .invalid,
            lastInterval: .invalid,
            patchWidth: patchWidth,
            patchHeight: patchHeight,
            // Nothing is known about any buffer until one is handed over, and a record is
            // made for each as it arrives.
            buffers: []
        )
    }

    /// Keeps a copy of the picture a delivered frame carries, for idle frames to be built on.
    ///
    /// **Why there is a copy at all, and why it is here rather than on the idle path.** An
    /// idle sample carries no pixels that can be relied on, so the only picture this path can
    /// draw from is one it kept, and the only moment a picture is in hand is while a frame
    /// the stream delivered is still in hand. This runs before the pointer is drawn into that
    /// frame, so what is kept is the screen rather than the screen with an arrow in it.
    ///
    /// **What it costs, which is the price of idle samples having no pixels.** One
    /// whole-frame copy for every frame the stream delivers. On a screen that is changing
    /// that is one per frame of the encoder's own work — a few per cent of it, and it buys
    /// nothing at all until the pointer moves. On a screen quiet enough to need idle frames
    /// the stream delivers nothing, so it costs nothing, and that is the screen this path
    /// exists for. Stated plainly: the frames the client is already being sent pay for the
    /// pointer's smoothness on the screen where nothing else is happening.
    ///
    /// **A screen nothing is happening on costs one copy, once.** The copy is per delivered
    /// frame, not per idle frame, so a screen that goes still and stays still pays for the
    /// picture once and then keeps reusing it — the copies would otherwise be the whole of
    /// what this design was built to avoid, and on the screen it was built for there are
    /// none of them after the first.
    ///
    /// A failure here is not a failure of the frame — it is called before anything about the
    /// frame has been decided and returns without touching it. What it costs is the idle
    /// frames until the next one, because the picture is left as it was and the generation
    /// is not advanced: a buffer holding the previous picture still matches, so the pointer
    /// is drawn over a screen one frame old rather than not drawn at all.
    private func refresh(from frame: CVPixelBuffer, geometry: FrameGeometry) {
        let width = CVPixelBufferGetWidthOfPlane(frame, 0)
        let height = CVPixelBufferGetHeightOfPlane(frame, 0)

        lock.withLock {
            var scratch: Scratch
            if let existing = self.scratch, existing.width == width, existing.height == height {
                scratch = existing
            } else {
                // **Made and filled in the same call, and that is not tidiness.** A picture
                // that is kept but empty is a picture the idle path refuses to use, and
                // refuses until the stream delivers another frame — which on a screen that
                // has gone still it never does. Making it and leaving it for next time would
                // put the pointer back to moving only when the display changes, which is the
                // whole of what this was built to stop.
                guard let fresh = makeScratch(width: width, height: height, geometry: geometry) else {
                    self.scratch = nil
                    return
                }
                scratch = fresh
            }

            // Held across the copy, which is the one moment this lock is held for something
            // slow — a few hundred microseconds for a display-sized frame. A preference
            // changing on the main actor waits that long, the same trade ``draw`` already
            // makes one frame at a time.
            guard CVPixelBufferLockBaseAddress(scratch.picture, []) == kCVReturnSuccess else { return }
            defer { CVPixelBufferUnlockBaseAddress(scratch.picture, []) }

            guard Self.copyPicture(from: frame, into: scratch.picture) else { return }
            scratch.generation += 1
            scratch.holdsPicture = true
            scratch.pictureArrived = true
            scratch.geometry = geometry
            self.scratch = scratch
        }
    }

    /// Copies a whole picture, both planes, out of one locked buffer and into another.
    ///
    /// The one place this path copies more than the pointer's own pixels. It runs when the
    /// picture itself is no longer the one the buffer holds, and the reason it has to be a
    /// whole copy is that nothing here knows which pixels those were — a stream reporting a
    /// frame rather than an idle sample says the display changed without saying where.
    ///
    /// Reports whether it managed it, because a half-copied picture is not one to advance a
    /// generation over: the caller would then have pool buffers claiming to hold a screen
    /// that is only partly in them.
    @discardableResult
    private static func copyPicture(from source: CVPixelBuffer, into destination: CVPixelBuffer) -> Bool {
        copyPlane(0, from: source, into: destination) && copyPlane(1, from: source, into: destination)
    }

    /// Copies one plane, row for row, taking the narrower of the two strides so neither
    /// buffer is read or written past its end. The two are the frame's own size in practice —
    /// the pool was built from those dimensions — so this is a memcpy and not a resample.
    private static func copyPlane(_ index: Int, from source: CVPixelBuffer, into destination: CVPixelBuffer) -> Bool {
        guard let sourceBase = CVPixelBufferGetBaseAddressOfPlane(source, index),
              let destinationBase = CVPixelBufferGetBaseAddressOfPlane(destination, index)
        else {
            return false
        }

        let sourceStride = CVPixelBufferGetBytesPerRowOfPlane(source, index)
        let destinationStride = CVPixelBufferGetBytesPerRowOfPlane(destination, index)
        let bytes = min(sourceStride, destinationStride)
        let rows = min(
            CVPixelBufferGetHeightOfPlane(source, index),
            CVPixelBufferGetHeightOfPlane(destination, index)
        )
        guard bytes > 0, rows > 0 else { return false }

        let sourceRows = sourceBase.assumingMemoryBound(to: UInt8.self)
        let destinationRows = destinationBase.assumingMemoryBound(to: UInt8.self)
        for row in 0..<rows {
            memcpy(destinationRows + row * destinationStride, sourceRows + row * sourceStride, bytes)
        }
        return true
    }

    /// Copies a region of the luma plane out, packed at the region's own width.
    private func save(
        _ region: Region,
        from plane: UnsafeMutablePointer<UInt8>,
        stride: Int,
        into patch: inout [UInt8]
    ) {
        patch.withUnsafeMutableBufferPointer { destination in
            guard let base = destination.baseAddress else { return }
            for row in 0..<region.height {
                memcpy(
                    base + row * region.width,
                    plane + (region.y + row) * stride + region.x,
                    region.width
                )
            }
        }
    }

    /// Puts a region saved by ``save(_:from:stride:into:)`` back where it came from.
    private func restore(
        _ region: Region,
        from patch: [UInt8],
        into plane: UnsafeMutablePointer<UInt8>,
        stride: Int
    ) {
        patch.withUnsafeBufferPointer { source in
            guard let base = source.baseAddress else { return }
            for row in 0..<region.height {
                memcpy(
                    plane + (region.y + row) * stride + region.x,
                    base + row * region.width,
                    region.width
                )
            }
        }
    }

    /// The rectangle the pointer covers at this tip and scale, before anything is clipped.
    ///
    /// The union of every polygon's bounds rather than the outline's own silhouette. What it
    /// is for is saving and putting back the pixels the pointer is about to cover, and a
    /// rectangle a little too big costs a few rows while one a pixel too small leaves part
    /// of the last pointer behind — a trail of arrows across the picture, which is the one
    /// artefact this path could produce that looks like the picture is broken.
    private func bounds(tip: CGPoint, scale: CGFloat) -> CGRect {
        var minX = CGFloat.greatestFiniteMagnitude
        var minY = CGFloat.greatestFiniteMagnitude
        var maxX = -CGFloat.greatestFiniteMagnitude
        var maxY = -CGFloat.greatestFiniteMagnitude

        for point in vertices {
            let x = tip.x + point.x * scale
            let y = tip.y + point.y * scale
            minX = min(minX, x)
            maxX = max(maxX, x)
            minY = min(minY, y)
            maxY = max(maxY, y)
        }

        return CGRect(x: minX, y: minY, width: maxX - minX, height: maxY - minY)
    }

    /// A rectangle of the luma plane, in pixels, clipped to it.
    ///
    /// Rounded outward, because the rasteriser decides what to fill by rounding crossings
    /// per row: a box tight to the outline's own coordinates leaves the outermost row and
    /// column of a filled span outside the region that gets saved and put back, and those
    /// pixels are the pointer staying behind when it moves.
    private static func region(_ box: CGRect, width: Int, height: Int) -> Region? {
        guard box.minX.isFinite, box.minY.isFinite, box.maxX.isFinite, box.maxY.isFinite else {
            return nil
        }
        let first = max(0, Int(box.minX.rounded(.down)))
        let last = min(width - 1, Int(box.maxX.rounded(.up)))
        let top = max(0, Int(box.minY.rounded(.down)))
        let bottom = min(height - 1, Int(box.maxY.rounded(.up)))
        guard last >= first, bottom >= top else { return nil }
        return Region(x: first, y: top, width: last - first + 1, height: bottom - top + 1)
    }

    // MARK: - Reporting

    /// Says once, and never again, why a frame went out with no pointer drawn into it.
    ///
    /// **Because nothing else would say it at all.** A pointer that is missing looks exactly
    /// like a pointer that was never asked for — the frames are the frames either way, and the
    /// switch in the window is the only evidence. Whatever stops the drawing here is a
    /// property of the stream or of the pixel format rather than of one frame, so it holds for
    /// every frame after the first, and one line is enough to tell a bug from a preference.
    /// Every frame would be sixty lines a second of the same sentence.
    ///
    /// Deliberately not called for the pointer being somewhere else: that is ordinary, and it
    /// is most of the time.
    private func report(_ reason: String) {
        let isFirst = lock.withLock { () -> Bool in
            guard !reportedRefusal else { return false }
            reportedRefusal = true
            return true
        }
        guard isFirst else { return }
        overlayLog.notice("no pointer drawn into a frame: \(reason, privacy: .public)")
    }

    /// Fills one polygon into the luma plane.
    ///
    /// A scanline fill rather than a test per pixel, because the work is in the pointer's
    /// outline and not in its area: each of the few hundred rows it covers crosses the
    /// outline at a handful of places, and finding those places is a walk over its edges
    /// instead of a walk over every pixel inside it.
    private func rasterize(
        _ pass: Pass,
        tip: CGPoint,
        scale: CGFloat,
        plane: UnsafeMutablePointer<UInt8>,
        stride: Int,
        width: Int,
        height: Int
    ) {
        // One crossing per edge is the worst a row can have, and this is what keeps the fixed
        // scratch array honest without a bounds check inside the loop.
        guard pass.range.count <= intersections.count else { return }

        let last = pass.range.upperBound - 1
        guard last > pass.range.lowerBound else { return }

        // The polygon's bounds in pixels, clipped to the plane: the pointer's tip can sit at
        // the very edge of the picture, which puts most of the arrow outside it.
        var minX = CGFloat.greatestFiniteMagnitude
        var maxX = -CGFloat.greatestFiniteMagnitude
        var minY = CGFloat.greatestFiniteMagnitude
        var maxY = -CGFloat.greatestFiniteMagnitude

        var index = pass.range.lowerBound
        while index < last {
            let a = vertices[index]
            let b = vertices[index + 1]
            let ax = tip.x + a.x * scale
            let bx = tip.x + b.x * scale
            let ay = tip.y + a.y * scale
            let by = tip.y + b.y * scale

            minX = min(minX, min(ax, bx))
            maxX = max(maxX, max(ax, bx))
            minY = min(minY, min(ay, by))
            maxY = max(maxY, max(ay, by))

            index += 1
        }

        let firstRow = max(0, Int(minY.rounded(.down)))
        let lastRow = min(height - 1, Int(maxY.rounded(.up)))
        guard firstRow <= lastRow, maxX >= 0, minX <= CGFloat(width - 1) else { return }

        for row in firstRow...lastRow {
            // Sampled at the row's centre, which is what a pixel covers.
            let sample = CGFloat(row) + 0.5
            var crossings = 0

            var index = pass.range.lowerBound
            while index < last {
                let ay = tip.y + vertices[index].y * scale
                let by = tip.y + vertices[index + 1].y * scale

                // Half-open in y, so a row that runs exactly through a vertex is counted by
                // one of the two edges meeting there and not by both — which is what stops
                // that vertex from opening and closing a span in the same row. Horizontal
                // edges fall out of this for free: they never straddle the sample.
                if (ay <= sample) != (by <= sample) {
                    let ax = tip.x + vertices[index].x * scale
                    let bx = tip.x + vertices[index + 1].x * scale
                    let t = (sample - ay) / (by - ay)
                    intersections[crossings] = ax + t * (bx - ax)
                    crossings += 1
                }

                index += 1
            }

            guard crossings >= 2 else { continue }

            // By hand, because there are at most seven of them, and because a sort a frame can
            // call eight times is not a place to allocate.
            for i in 1..<crossings {
                let value = intersections[i]
                var j = i
                while j > 0, intersections[j - 1] > value {
                    intersections[j] = intersections[j - 1]
                    j -= 1
                }
                intersections[j] = value
            }

            let line = plane + row * stride
            var pair = 0
            while pair + 1 < crossings {
                // A pixel is filled when its centre is inside the span, which is the same rule
                // the rows are sampled by.
                let from = max(0, Int((intersections[pair] - 0.5).rounded(.up)))
                let to = min(width - 1, Int((intersections[pair + 1] - 0.5).rounded(.down)))
                if from <= to {
                    memset(line + from, Int32(pass.value), to - from + 1)
                }
                pair += 2
            }
        }
    }

    // MARK: - Shape

    /// The pointer as filled polygons, in its own units: every edge stroked first, then the
    /// outline itself over the top of them.
    private static func shape() -> (vertices: [CGPoint], passes: [Pass]) {
        var vertices: [CGPoint] = []
        var passes: [Pass] = []

        for index in outline.indices {
            let quad = stroke(from: outline[index], to: outline[(index + 1) % outline.count])
            guard let first = quad.first else { continue }
            let start = vertices.count
            vertices.append(contentsOf: quad)
            vertices.append(first)
            passes.append(Pass(range: start..<vertices.count, value: edge))
        }

        let start = vertices.count
        vertices.append(contentsOf: outline)
        vertices.append(outline[0])
        passes.append(Pass(range: start..<vertices.count, value: ink))

        return (vertices, passes)
    }

    /// A segment as the rectangle it covers, which is all a stroked edge is.
    private static func stroke(from a: CGPoint, to b: CGPoint) -> [CGPoint] {
        let dx = b.x - a.x
        let dy = b.y - a.y
        let length = (dx * dx + dy * dy).squareRoot()
        guard length > 0 else { return [] }

        let half = edgeWidth / 2
        let nx = -dy / length * half
        let ny = dx / length * half

        return [
            CGPoint(x: a.x + nx, y: a.y + ny),
            CGPoint(x: b.x + nx, y: b.y + ny),
            CGPoint(x: b.x - nx, y: b.y - ny),
            CGPoint(x: a.x - nx, y: a.y - ny),
        ]
    }
}
