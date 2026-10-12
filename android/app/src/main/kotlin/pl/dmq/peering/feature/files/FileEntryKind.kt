package pl.dmq.peering.feature.files

import pl.dmq.peering.wire.RemoteDirectoryEntry

/** What a row says about an entry under its name. A file's size is shown only for the plain kinds. */
enum class FileEntryKind {
    FOLDER,
    FOLDER_LINK,
    LINK,
    EXECUTABLE,
    FILE,
    ;

    companion object {
        fun of(entry: RemoteDirectoryEntry): FileEntryKind = when {
            entry.isDirectory && entry.isSymlink -> FOLDER_LINK
            entry.isDirectory -> FOLDER
            entry.isSymlink -> LINK
            entry.isExecutable -> EXECUTABLE
            else -> FILE
        }
    }
}
