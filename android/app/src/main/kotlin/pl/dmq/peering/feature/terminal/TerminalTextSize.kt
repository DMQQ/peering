package pl.dmq.peering.feature.terminal

import androidx.annotation.StringRes
import pl.dmq.peering.R
import pl.dmq.peering.session.ports.KeyValueStore

/** The log's type size, the same four steps as the iPhone. */
enum class TerminalTextSize(val points: Int, @StringRes val label: Int) {
    TINY(7, R.string.terminal_size_tiny),
    SMALL(9, R.string.terminal_size_small),
    REGULAR(12, R.string.terminal_size_default),
    LARGE(15, R.string.terminal_size_large),
}

class TerminalTextSizeSetting(private val store: KeyValueStore) {
    fun read(): TerminalTextSize =
        TerminalTextSize.entries.firstOrNull { it.points == store.read(KEY)?.toIntOrNull() } ?: TerminalTextSize.REGULAR

    fun write(size: TerminalTextSize) = store.write(KEY, size.points.toString())

    private companion object {
        const val KEY = "terminal_text_size"
    }
}
