package pl.dmq.peering.session.connection

import pl.dmq.peering.wire.JoystickMove
import pl.dmq.peering.wire.LaunchApplication
import pl.dmq.peering.wire.LockScreen
import pl.dmq.peering.wire.OpenNewWindow
import pl.dmq.peering.wire.PerformWindowAction
import pl.dmq.peering.wire.RefreshSpacePreviews
import pl.dmq.peering.wire.RemoteCommand
import pl.dmq.peering.wire.ServerHello
import pl.dmq.peering.wire.SetPrivacyMode
import pl.dmq.peering.wire.SwitchSpace
import pl.dmq.peering.wire.SwitchToSpace

private const val MAC_PLATFORM = "macos"
private const val WINDOWS_PLATFORM = "windows"

/** What a host's platform can do, read from [ServerHello.hostPlatform]; a host that omits it is a Mac. */
enum class HostCapability {
    /** Locking the computer and darkening its displays, which both the Mac and the Windows host do. */
    ScreenControls,

    /** Spaces, launching apps and window actions, and the joystick: a Mac does these and a Windows host does not. */
    MacControls;

    fun declaredBy(hello: ServerHello): Boolean = when (this) {
        ScreenControls -> hello.hostPlatform == null || hello.hostPlatform == MAC_PLATFORM || hello.hostPlatform == WINDOWS_PLATFORM
        MacControls -> hello.hostPlatform == null || hello.hostPlatform == MAC_PLATFORM
    }

    companion object {
        /** The capability a command needs before it may be sent, or null when every host accepts it. */
        fun requiredBy(command: RemoteCommand): HostCapability? = when (command) {
            is LockScreen, is SetPrivacyMode -> ScreenControls
            is SwitchSpace, is SwitchToSpace, is RefreshSpacePreviews, is LaunchApplication, is PerformWindowAction, is OpenNewWindow, is JoystickMove -> MacControls
            else -> null
        }
    }
}
