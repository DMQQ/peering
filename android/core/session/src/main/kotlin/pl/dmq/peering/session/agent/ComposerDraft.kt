package pl.dmq.peering.session.agent

/** What the composer holds for one session: unsent text and the files attached to it. */
data class ComposerDraft(
    val text: String = "",
    val attachedPaths: List<String> = emptyList(),
) {
    val isEmpty: Boolean get() = text.isEmpty() && attachedPaths.isEmpty()

    /** The files go first as `@path`, the CLIs' own way to read one; the transcript turns them back into chips. */
    fun toPrompt(): String = (attachedPaths.map { "@$it" } + text).filter { it.isNotEmpty() }.joinToString(" ")

    /** Nothing is sent while a file is still uploading; an empty text needs at least one file that arrived. */
    fun canSend(isUploading: Boolean): Boolean {
        if (isUploading) return false
        return text.isNotBlank() || attachedPaths.isNotEmpty()
    }
}

/** Where an uploaded file lands on the Mac: in the chat's own folder. */
fun attachmentPath(folder: String, name: String): String = if (folder.endsWith("/")) folder + name else "$folder/$name"
