package pl.dmq.peering.feature.files

fun fileSizeLabel(bytes: Long): String = FileSize.of(bytes).label()
