package pl.dmq.peering.feature.sessionmode

/**
 * What one edit of the typing field means to the computer, whose cursor sits at the end of what was typed: [deleted]
 * characters taken off the end, then [appended] typed. An edit in the middle retypes everything after it.
 */
data class TypedDiff(val appended: String, val deleted: Int) {
    companion object {
        fun of(old: String, new: String): TypedDiff {
            val kept = old.commonPrefixWith(new).length
            val removed = old.substring(kept)
            return TypedDiff(new.substring(kept), removed.codePointCount(0, removed.length))
        }
    }
}
