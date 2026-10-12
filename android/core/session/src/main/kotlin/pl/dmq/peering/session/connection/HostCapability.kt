package pl.dmq.peering.session.connection

import pl.dmq.peering.wire.AddVirtualDisplay
import pl.dmq.peering.wire.CaptureSource
import pl.dmq.peering.wire.JoystickMove
import pl.dmq.peering.wire.LaunchApplication
import pl.dmq.peering.wire.LockScreen
import pl.dmq.peering.wire.OpenNewWindow
import pl.dmq.peering.wire.PerformWindowAction
import pl.dmq.peering.wire.PushClipboardImage
import pl.dmq.peering.wire.RefreshSourceThumbnails
import pl.dmq.peering.wire.RemoteCommand
import pl.dmq.peering.wire.RemoveVirtualDisplay
import pl.dmq.peering.wire.RenameVirtualDisplay
import pl.dmq.peering.wire.ReportDeviceOrientation
import pl.dmq.peering.wire.ServerHello
import pl.dmq.peering.wire.SetCaptureSource
import pl.dmq.peering.wire.SetPrivacyMode
import pl.dmq.peering.wire.SetVideoEnabled
import pl.dmq.peering.wire.SwitchSpace
import pl.dmq.peering.wire.WatchSourceThumbnails

private const val MAC_PLATFORM = "macos"

/** A feature the host declares in its server hello. An older host omits the flag, which reads as not declared; a host
 * that omits its platform predates the Windows host and is a Mac. */
enum class HostCapability {
    VideoPause,
    Mosaic,
    ClipboardImages,
    VirtualDisplayManagement,
    SourceThumbnails,
    DeviceOrientation,
    ClientState,

    /** Locking, privacy mode, Spaces, launching apps and window actions, and the joystick: a Mac does these and a Windows host does not. */
    MacControls;

    fun declaredBy(hello: ServerHello): Boolean = when (this) {
        VideoPause -> hello.supportsVideoPause
        Mosaic -> hello.supportsMosaic
        ClipboardImages -> hello.supportsClipboardImages
        VirtualDisplayManagement -> hello.supportsVirtualDisplayManagement
        SourceThumbnails -> hello.supportsSourceThumbnails
        DeviceOrientation -> hello.supportsDeviceOrientation
        ClientState -> hello.supportsClientState
        MacControls -> hello.hostPlatform == null || hello.hostPlatform == MAC_PLATFORM
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
            is LockScreen, is SetPrivacyMode, is SwitchSpace, is LaunchApplication, is PerformWindowAction, is OpenNewWindow, is JoystickMove -> MacControls
            else -> null
        }
    }
}
