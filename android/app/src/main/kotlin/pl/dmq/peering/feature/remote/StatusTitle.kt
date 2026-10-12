package pl.dmq.peering.feature.remote

/** The pill's second line: the mosaic's "N windows" label while one is up, else the name of the source on screen. */
fun sourceLine(sourceTitle: String?, mosaicLabel: String?): String? = mosaicLabel ?: sourceTitle
