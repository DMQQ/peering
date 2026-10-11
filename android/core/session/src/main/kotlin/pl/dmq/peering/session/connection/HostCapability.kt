package pl.dmq.peering.session.connection

import pl.dmq.peering.wire.AddVirtualDisplay
import pl.dmq.peering.wire.CaptureSource
import pl.dmq.peering.wire.PushClipboardImage
import pl.dmq.peering.wire.RefreshSourceThumbnails
import pl.dmq.peering.wire.RemoteCommand
import pl.dmq.peering.wire.RemoveVirtualDisplay
import pl.dmq.peering.wire.RenameVirtualDisplay
import pl.dmq.peering.wire.ReportDeviceOrientation
import pl.dmq.peering.wire.ServerHello
import pl.dmq.peering.wire.SetCaptureSource
import pl.dmq.peering.wire.SetVideoEnabled
import pl.dmq.peering.wire.WatchSourceThumbnails

/** A feature the host declares in its server hello. An older host omits the flag, which reads as not declared. */
enum class HostCapability {
    VideoPause,
    Mosaic,
    ClipboardImages,
    VirtualDisplayManagement,
    SourceThumbnails,
    DeviceOrientation;

    fun declaredBy(hello: ServerHello): Boolean = when (this) {
        VideoPause -> hello.supportsVideoPause
        Mosaic -> hello.supportsMosaic
        ClipboardImages -> hello.supportsClipboardImages
        VirtualDisplayManagement -> hello.supportsVirtualDisplayManagement
        SourceThumbnails -> hello.supportsSourceThumbnails
        DeviceOrientation -> hello.supportsDeviceOrientation
    } == true

    companion object {
        /** The capability a command needs before it may be sent, or null when every host accepts it. */
        fun requiredBy(command: RemoteCommand): HostCapability? = when (command) {
            is SetVideoEnabled -> VideoPause
            is SetCaptureSource -> if (command.source is CaptureSource.Mosaic) Mosaic else null
            is PushClipboardImage -> ClipboardImages
            is AddVirtualDisplay, is RemoveVirtualDisplay, is RenameVirtualDisplay -> VirtualDisplayManagement
            is WatchSourceThumbnails, is RefreshSourceThumbnails -> SourceThumbnails
            is ReportDeviceOrientation -> DeviceOrientation
            else -> null
        }
    }
}
