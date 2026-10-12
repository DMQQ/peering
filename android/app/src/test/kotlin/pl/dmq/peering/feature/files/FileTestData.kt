package pl.dmq.peering.feature.files

import pl.dmq.peering.wire.RemoteDirectoryEntry

internal fun folder(name: String, modified: Double? = null) = RemoteDirectoryEntry(
    name = name, isDirectory = true, isSymlink = false, size = 0, permissions = "drwxr-xr-x", modified = modified,
)

internal fun file(name: String, size: Long = 1, modified: Double? = null, permissions: String = "-rw-r--r--") = RemoteDirectoryEntry(
    name = name, isDirectory = false, isSymlink = false, size = size, permissions = permissions, modified = modified,
)
