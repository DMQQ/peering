package pl.dmq.peering.feature.files

class FakeGalleryWriter(private val reserves: String? = "content://media/external/video/media/7") : GalleryWriter {
    val calls = mutableListOf<String>()

    override suspend fun write(target: GalleryTarget, bytes: ByteArray): Boolean {
        calls += "write ${target.displayName} ${bytes.size}"
        return true
    }

    override suspend fun reserve(target: GalleryTarget): String? {
        calls += "reserve ${target.displayName}"
        return reserves
    }

    override fun report(saved: Boolean) {
        calls += "report $saved"
    }
}
