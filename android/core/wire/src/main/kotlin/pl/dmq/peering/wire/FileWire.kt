package pl.dmq.peering.wire

import kotlinx.serialization.KSerializer
import kotlinx.serialization.SerialName
import kotlinx.serialization.Serializable
import kotlinx.serialization.json.JsonObject

/**
 * One entry of a folder listing. There is no path: it is the listing's path plus [name]. [isDirectory] is
 * true for a symbolic link that points at a folder, because that is what a tap on the row asks; [isSymlink]
 * tells the two apart. [modified] is seconds since 2001-01-01.
 */
@Serializable
data class RemoteDirectoryEntry(
    val name: String,
    val isDirectory: Boolean,
    val isSymlink: Boolean,
    val size: Long,
    val permissions: String,
    val modified: Double? = null,
) {
    /**
     * Only a regular file counts: a symbolic link's own mode carries the execute bit whether or not its target
     * does, so a link would be a run button that fails. Setuid, setgid and sticky show as `s` and `t` in the
     * execute slot, and appear only where execute is set too.
     */
    val isExecutable: Boolean
        get() = permissions.length == TYPE_AND_MODE_LENGTH &&
            permissions[0] == '-' &&
            EXECUTE_SLOTS.any { permissions[it] in EXECUTE_MARKS }

    companion object {
        private const val TYPE_AND_MODE_LENGTH = 10
        private val EXECUTE_SLOTS = listOf(3, 6, 9)
        private val EXECUTE_MARKS = setOf('x', 's', 't')
    }
}

/** What a created entry is. Narrower than [RemoteFileKind], which says how a file is drawn. */
@Serializable
enum class RemoteEntryKind {
    @SerialName("file")
    FILE,

    @SerialName("folder")
    FOLDER,
}

/** How the client draws a file's contents. */
@Serializable
enum class RemoteFileKind {
    @SerialName("text")
    TEXT,

    @SerialName("image")
    IMAGE,

    @SerialName("svg")
    SVG,

    @SerialName("pdf")
    PDF,

    @SerialName("video")
    VIDEO,
}

/** A change to one entry. [Rename] takes a bare name, so it cannot move a file across folders. */
@Serializable(with = RemoteFileOperationSerializer::class)
sealed class RemoteFileOperation {
    @Serializable
    data class Create(val path: String, val kind: RemoteEntryKind) : RemoteFileOperation()

    @Serializable
    data class Rename(val path: String, val to: String) : RemoteFileOperation()

    @Serializable
    data class Delete(val path: String) : RemoteFileOperation()
}

internal object RemoteFileOperationSerializer : SwiftCaseSerializer<RemoteFileOperation>() {
    private val cases: List<UnionCase<RemoteFileOperation>> = listOf(
        unionCase<RemoteFileOperation, RemoteFileOperation.Create>("create"),
        unionCase<RemoteFileOperation, RemoteFileOperation.Rename>("rename"),
        unionCase<RemoteFileOperation, RemoteFileOperation.Delete>("delete"),
    )

    override fun encodeCase(value: RemoteFileOperation): JsonObject = encodeUnion(cases, value)

    override fun decodeCase(json: JsonObject): RemoteFileOperation = decodeUnion(cases, json)
}
