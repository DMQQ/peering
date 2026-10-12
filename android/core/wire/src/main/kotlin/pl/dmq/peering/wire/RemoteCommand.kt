package pl.dmq.peering.wire

import kotlinx.serialization.KSerializer
import kotlinx.serialization.SerialName
import kotlinx.serialization.Serializable
import kotlinx.serialization.descriptors.PrimitiveKind
import kotlinx.serialization.descriptors.PrimitiveSerialDescriptor
import kotlinx.serialization.descriptors.SerialDescriptor
import kotlinx.serialization.encoding.Decoder
import kotlinx.serialization.encoding.Encoder

/** A command the phone sends to the Mac. Each case's JSON is in protocol.md section 8. */
sealed class RemoteCommand {
    /** How a newer command of this kind combines with an unsent one while the send queue is busy. */
    open val coalescing: Coalescing get() = Coalescing.NONE

    /** Must survive a full send queue, because losing it would leave the host stuck. */
    open val isCritical: Boolean get() = false

    /** Pointer and keyboard input, which a host in observe mode refuses. */
    open val isUserInput: Boolean get() = false

    /** What a mosaic refuses: a point or a keystroke, since it cannot tell which window they mean. Space switching still works. */
    val isBlockedByMosaic: Boolean get() = isUserInput && this !is SwitchSpace && this !is SwitchToSpace

    fun toJson(): String = encodeRemoteCommand(this)

    companion object {
        fun parse(text: String): RemoteCommand = decodeRemoteCommand(text)
    }
}

/** Raw values match `CGEventFlags` (shift 1 shl 17 to command 1 shl 20), so the host passes them straight through. */
@Serializable
@JvmInline
value class Modifiers(val bits: Long) {
    companion object {
        const val SHIFT: Long = 1L shl 17
        const val CONTROL: Long = 1L shl 18
        const val OPTION: Long = 1L shl 19
        const val COMMAND: Long = 1L shl 20

        /** Asks for an F-key's printed action instead of the key itself. */
        const val TOP_ROW_ACTION: Long = 1L shl 8
    }
}

enum class MouseButton(val code: Int) {
    LEFT(0),
    RIGHT(1),
    MIDDLE(2),
}

/** Written as the integer 0, 1 or 2, as Swift's `UInt8` raw value is. */
object MouseButtonSerializer : KSerializer<MouseButton> {
    override val descriptor: SerialDescriptor = PrimitiveSerialDescriptor("MouseButton", PrimitiveKind.INT)

    override fun serialize(encoder: Encoder, value: MouseButton) {
        encoder.encodeInt(value.code)
    }

    override fun deserialize(decoder: Decoder): MouseButton {
        val code = decoder.decodeInt()
        return MouseButton.entries.firstOrNull { it.code == code }
            ?: throw SwiftEnumException("unknown mouse button $code")
    }
}

@Serializable
enum class SpaceDirection {
    @SerialName("left") LEFT,
    @SerialName("right") RIGHT,
}

@Serializable
enum class WindowAction {
    @SerialName("close") CLOSE,
    @SerialName("minimize") MINIMIZE,
    @SerialName("zoom") ZOOM,
}
