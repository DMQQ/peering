package pl.dmq.peering.session.video

import kotlinx.serialization.json.JsonElement
import pl.dmq.peering.wire.CaptureCatalog
import pl.dmq.peering.wire.CaptureSource
import pl.dmq.peering.wire.CaptureSourceDescriptor
import pl.dmq.peering.wire.RemoteCommand
import pl.dmq.peering.wire.SetCaptureSource

/**
 * Which capture source the phone is watching. A switch to a source of another pixel size owes the picture a new
 * config from the Mac; the same size owes none. The catalogue is the only thing that says a source's size, so a source
 * it does not describe owes nothing rather than a config that may never come.
 */
class SourceSelection(restored: CaptureSource? = null) {
    /** The source the picture is from, or null before one is known. */
    var chosen: CaptureSource? = restored
        private set

    /** Kept across reconnects: the source sent in the next hello, so the Mac can resume it. */
    var resumeSource: CaptureSource? = restored
        private set

    /** New configs the Mac still owes after switches. Each received config pays one back. */
    var configUpdatesOwed: Int = 0
        private set

    private var catalog: CaptureCatalog? = null

    fun choose(source: CaptureSource): RemoteCommand {
        val previous = chosen?.let(::descriptorFor)
        val next = descriptorFor(source)
        if (previous != null && next != null && previous.pixelSize != next.pixelSize) configUpdatesOwed += 1
        chosen = source
        resumeSource = source
        return SetCaptureSource(source)
    }

    /**
     * Records a catalogue. When the chosen source is no longer offered, the first display is chosen in its place and
     * the switch is returned for the Mac. A mosaic has no catalogue row, so it is never treated as gone.
     */
    fun onCatalog(next: CaptureCatalog): RemoteCommand? {
        catalog = next
        val current = chosen ?: return null
        if (current is CaptureSource.Mosaic || descriptorFor(current) != null) return null
        val fallback = next.displays.firstOrNull()?.source
        if (fallback == null) {
            chosen = null
            resumeSource = null
            return null
        }
        return choose(fallback)
    }

    fun onVideoConfig() {
        if (configUpdatesOwed > 0) configUpdatesOwed -= 1
    }

    /** The resume source as the hello carries it, or null when there is none. */
    fun resumeSourceJson(): JsonElement? = resumeSource?.toJson()

    /** The map from taps on a view of the picture to the source, or null while the active source has no size. */
    fun inputTransform(viewWidth: Double, viewHeight: Double): InputTransform? =
        chosen?.let(::descriptorFor)?.let { InputTransform.fitted(it.pixelSize, viewWidth, viewHeight) }

    private fun descriptorFor(source: CaptureSource): CaptureSourceDescriptor? {
        val known = catalog ?: return null
        return (known.displays + known.applications + known.windows).firstOrNull { it.source == source }
    }
}
