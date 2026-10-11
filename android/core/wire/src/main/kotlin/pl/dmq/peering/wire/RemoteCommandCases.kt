package pl.dmq.peering.wire

import kotlinx.serialization.SerialName
import kotlinx.serialization.Serializable

@Serializable
data class MouseMove(val to: NormalizedPoint) : RemoteCommand() {
    override val coalescing get() = Coalescing.REPLACE_LATEST
    override val isUserInput get() = true
}

@Serializable
data class MouseDown(@Serializable(MouseButtonSerializer::class) val button: MouseButton) : RemoteCommand() {
    override val isCritical get() = true
    override val isUserInput get() = true
}

@Serializable
data class MouseUp(@Serializable(MouseButtonSerializer::class) val button: MouseButton) : RemoteCommand() {
    override val isCritical get() = true
    override val isUserInput get() = true
}

@Serializable
data class Scroll(val dx: Double, val dy: Double) : RemoteCommand() {
    override val coalescing get() = Coalescing.ACCUMULATE
    override val isUserInput get() = true
}

@Serializable
data class KeyDown(val keyCode: Int, val modifiers: Modifiers) : RemoteCommand() {
    override val isCritical get() = true
    override val isUserInput get() = true
}

@Serializable
data class KeyUp(val keyCode: Int, val modifiers: Modifiers) : RemoteCommand() {
    override val isCritical get() = true
    override val isUserInput get() = true
}

@Serializable
data class TextInput(@SerialName("_0") val text: String) : RemoteCommand() {
    override val isUserInput get() = true
}

@Serializable
data class SwitchSpace(val direction: SpaceDirection) : RemoteCommand() {
    override val isUserInput get() = true
}

@Serializable
data class SwitchToSpace(val display: Long, val index: Int) : RemoteCommand() {
    override val isUserInput get() = true
}

@Serializable
data class JoystickMove(val dx: Double, val dy: Double) : RemoteCommand() {
    override val coalescing get() = Coalescing.ACCUMULATE
    override val isUserInput get() = true
}

@Serializable
data class SetCaptureSource(
    @SerialName("_0") @Serializable(CaptureSourceSerializer::class) val source: CaptureSource,
) : RemoteCommand() {
    override val isCritical get() = true
}

@Serializable
data class LaunchApplication(val bundleIdentifier: String) : RemoteCommand() {
    override val isCritical get() = true
}

/** A value of 0 for either field means "keep current". */
@Serializable
data class SetStreamQuality(val fps: Int, val bitrateKbps: Int) : RemoteCommand()

@Serializable
data class SetVideoEnabled(@SerialName("_0") val enabled: Boolean) : RemoteCommand() {
    override val isCritical get() = true
}

@Serializable
data object RefreshSpacePreviews : RemoteCommand()

@Serializable
data object RefreshSourceThumbnails : RemoteCommand()

@Serializable
data class WatchSourceThumbnails(@SerialName("_0") val watching: Boolean) : RemoteCommand()

@Serializable
data class SetPrivacyMode(val enabled: Boolean) : RemoteCommand() {
    override val isCritical get() = true
}

@Serializable
data object LockScreen : RemoteCommand() {
    override val isCritical get() = true
}

@Serializable
data object RequestClipboard : RemoteCommand()

@Serializable
data class PushClipboard(val text: String) : RemoteCommand() {
    override val isCritical get() = true
}

/** The PNG as padded base64 text. */
@Serializable
data class PushClipboardImage(val png: String) : RemoteCommand() {
    override val isCritical get() = true
}

@Serializable
data class ReportDeviceOrientation(val isLandscape: Boolean) : RemoteCommand() {
    override val coalescing get() = Coalescing.REPLACE_LATEST
}

@Serializable
data class AddVirtualDisplay(
    val name: String,
    val width: Int,
    val height: Int,
    val startLandscape: Boolean,
) : RemoteCommand()

@Serializable
data class RemoveVirtualDisplay(val displayID: Long) : RemoteCommand()

@Serializable
data class RenameVirtualDisplay(val displayID: Long, val name: String) : RemoteCommand()

@Serializable
data class PerformWindowAction(val windowID: Long, val action: WindowAction) : RemoteCommand()

@Serializable
data class OpenNewWindow(val bundleIdentifier: String) : RemoteCommand()
