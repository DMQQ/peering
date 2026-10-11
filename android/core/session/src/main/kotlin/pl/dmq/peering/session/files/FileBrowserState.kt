package pl.dmq.peering.session.files

/**
 * What the file browser shows. [browseFailure] and [listing] are not both set: a failed listing clears the folder
 * on screen, and a listing that arrives clears the failure.
 */
data class FileBrowserState(
    val listing: DirectoryModel? = null,
    val listingLoading: Boolean = false,
    val browseFailure: String? = null,
    val preview: FilePreview? = null,
    val transfer: FileTransfer = FileTransfer.Idle,
)
