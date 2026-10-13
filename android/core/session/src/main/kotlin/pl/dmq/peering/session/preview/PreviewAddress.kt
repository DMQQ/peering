package pl.dmq.peering.session.preview

import java.net.URI

/** A page on the computer's loopback: the port and the path with its query. */
data class PreviewAddress(val port: Int, val target: String) {
    /** The address the phone's web view is given. It never reaches the phone's own network: every request for it is answered by the proxy. */
    val url: String get() = "http://localhost:$port$target"

    /** What the address field shows. */
    val display: String get() = "localhost:$port$target"

    companion object {
        /**
         * What the user typed. `3000`, `localhost:3000/docs`, `127.0.0.1:5173` and a full `http://localhost:3000/` are
         * taken; any other host is not, so the field cannot be used to ask for the LAN or the internet.
         */
        fun fromTyped(text: String): PreviewAddress? {
            var typed = text.trim()
            typed.toIntOrNull()?.let { return of(it, "/") }
            for (prefix in listOf("http://", "https://")) {
                if (typed.lowercase().startsWith(prefix)) typed = typed.drop(prefix.length)
            }
            if ('@' in typed) return null
            return fromUrl("http://$typed")
        }

        /** An http(s) URL on `localhost` or `127.0.0.1` with an explicit port, else null. */
        fun fromUrl(url: String): PreviewAddress? {
            val uri = runCatching { URI(url) }.getOrNull() ?: return null
            val scheme = uri.scheme?.lowercase()
            if (scheme != "http" && scheme != "https") return null
            val host = uri.host ?: return null
            if (!PreviewPolicy.isLoopbackHost(host) || uri.userInfo != null || uri.port < 0) return null
            val path = uri.rawPath.orEmpty().ifEmpty { "/" }
            return of(uri.port, uri.rawQuery?.let { "$path?$it" } ?: path)
        }

        /**
         * Whether a URL names the phone's own loopback in any spelling, usable or not. A web view left to load one
         * would dial the phone itself, so every such URL is answered by the preview or refused, never passed on.
         */
        fun namesLoopback(url: String): Boolean {
            val authority = authorityPattern.find(url)?.groupValues?.get(1) ?: return false
            val hostAndPort = authority.substringAfterLast('@')
            val host = (if (hostAndPort.startsWith("[")) hostAndPort.substringBefore(']') + "]" else hostAndPort.substringBefore(':')).lowercase()
            return host == "localhost" || host.endsWith(".localhost") || host.startsWith("127.") ||
                host == "[::1]" || host == "::1" || host == "0.0.0.0"
        }

        private val authorityPattern = Regex("^[a-zA-Z][a-zA-Z0-9+.-]*://([^/?#]*)")

        private fun of(port: Int, target: String): PreviewAddress? =
            if (PreviewPolicy.isAllowed(port) && PreviewPolicy.isValidTarget(target)) PreviewAddress(port, target) else null
    }
}

/** What to do with a redirect an answer carries. */
sealed interface PreviewRedirect {
    data object NotARedirect : PreviewRedirect

    data class Follow(val address: PreviewAddress) : PreviewRedirect

    /** Leaves the loopback preview, which a page may not do. */
    data object Refuse : PreviewRedirect

    companion object {
        private val statuses = setOf(301, 302, 303, 307, 308)

        /** A 3xx's `Location`, resolved against the address that was asked for. A target on loopback is followed; anything else is refused. */
        fun of(status: Int, location: String?, from: PreviewAddress): PreviewRedirect {
            if (status !in statuses || location.isNullOrEmpty()) return NotARedirect
            val resolved = runCatching { URI(from.url).resolve(location).toString() }.getOrNull() ?: return Refuse
            return PreviewAddress.fromUrl(resolved)?.let(::Follow) ?: Refuse
        }
    }
}
