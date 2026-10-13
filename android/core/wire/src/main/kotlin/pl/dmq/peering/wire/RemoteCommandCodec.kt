package pl.dmq.peering.wire

import kotlinx.serialization.json.JsonElement
import kotlinx.serialization.json.JsonObject
import kotlinx.serialization.json.decodeFromJsonElement
import kotlinx.serialization.json.encodeToJsonElement

private class CaseCodec(
    val name: String,
    val type: Class<out RemoteCommand>,
    val decode: (JsonElement) -> RemoteCommand,
    val encode: (RemoteCommand) -> JsonElement,
)

private inline fun <reified T : RemoteCommand> caseCodec(name: String) = CaseCodec(
    name = name,
    type = T::class.java,
    decode = { WireJson.decodeFromJsonElement<T>(it) },
    encode = { WireJson.encodeToJsonElement(it as T) },
)

private val caseCodecs: List<CaseCodec> = listOf(
    caseCodec<MouseMove>("mouseMove"),
    caseCodec<MouseDown>("mouseDown"),
    caseCodec<MouseUp>("mouseUp"),
    caseCodec<Scroll>("scroll"),
    caseCodec<KeyDown>("keyDown"),
    caseCodec<KeyUp>("keyUp"),
    caseCodec<TextInput>("textInput"),
    caseCodec<SwitchSpace>("switchSpace"),
    caseCodec<SwitchToSpace>("switchToSpace"),
    caseCodec<JoystickMove>("joystickMove"),
    caseCodec<SetCaptureSource>("setCaptureSource"),
    caseCodec<LaunchApplication>("launchApplication"),
    caseCodec<SetStreamQuality>("setStreamQuality"),
    caseCodec<SetVideoEnabled>("setVideoEnabled"),
    caseCodec<RefreshSpacePreviews>("refreshSpacePreviews"),
    caseCodec<RefreshSourceThumbnails>("refreshSourceThumbnails"),
    caseCodec<WatchSourceThumbnails>("watchSourceThumbnails"),
    caseCodec<SetPrivacyMode>("setPrivacyMode"),
    caseCodec<LockScreen>("lockScreen"),
    caseCodec<RequestClipboard>("requestClipboard"),
    caseCodec<PushClipboard>("pushClipboard"),
    caseCodec<PushClipboardImage>("pushClipboardImage"),
    caseCodec<ReportDeviceOrientation>("reportDeviceOrientation"),
    caseCodec<AddVirtualDisplay>("addVirtualDisplay"),
    caseCodec<RemoveVirtualDisplay>("removeVirtualDisplay"),
    caseCodec<RenameVirtualDisplay>("renameVirtualDisplay"),
    caseCodec<PerformWindowAction>("performWindowAction"),
    caseCodec<OpenNewWindow>("openNewWindow"),
)

internal fun encodeRemoteCommand(command: RemoteCommand): String {
    val codec = caseCodecs.first { it.type == command.javaClass }
    val case = swiftCase(codec.name, codec.encode(command) as JsonObject)
    return WireJson.encodeToString(JsonObject.serializer(), case)
}

internal fun decodeRemoteCommand(text: String): RemoteCommand {
    val root = WireJson.parseToJsonElement(text) as? JsonObject
        ?: throw SwiftEnumException("a command must be a JSON object")
    val (name, fields) = root.swiftCase()
    val codec = caseCodecs.firstOrNull { it.name == name }
        ?: throw SwiftEnumException("unknown command case $name")
    return codec.decode(fields)
}
