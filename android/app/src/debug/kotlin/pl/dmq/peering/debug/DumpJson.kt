package pl.dmq.peering.debug

/** Renders the harness's state as one line of JSON. Plain Kotlin so a JVM test can check it. */
object DumpJson {
    fun render(value: Any?): String = StringBuilder().also { append(it, value) }.toString()

    private fun append(out: StringBuilder, value: Any?) {
        when (value) {
            null -> out.append("null")
            is Boolean, is Int, is Long -> out.append(value)
            is Number -> out.append(if (value.toDouble().isFinite()) value.toString() else "null")
            is Map<*, *> -> {
                out.append('{')
                value.entries.forEachIndexed { index, entry ->
                    if (index > 0) out.append(',')
                    quote(out, entry.key.toString())
                    out.append(':')
                    append(out, entry.value)
                }
                out.append('}')
            }
            is Iterable<*> -> {
                out.append('[')
                value.forEachIndexed { index, item ->
                    if (index > 0) out.append(',')
                    append(out, item)
                }
                out.append(']')
            }
            else -> quote(out, value.toString())
        }
    }

    private fun quote(out: StringBuilder, text: String) {
        out.append('"')
        for (char in text) {
            when {
                char == '"' -> out.append("\\\"")
                char == '\\' -> out.append("\\\\")
                char == '\n' -> out.append("\\n")
                char == '\r' -> out.append("\\r")
                char == '\t' -> out.append("\\t")
                char < ' ' -> out.append("\\u%04x".format(char.code))
                else -> out.append(char)
            }
        }
        out.append('"')
    }
}
