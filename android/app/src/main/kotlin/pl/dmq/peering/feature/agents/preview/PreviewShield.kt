package pl.dmq.peering.feature.agents.preview

/**
 * Keeps a previewed page from reaching the network around the proxy. WebSocket, WebTransport and WebRTC never pass
 * through `shouldInterceptRequest`, so a page from an untrusted repository could otherwise dial out of the phone and
 * probe its network. The policy stops sockets in every frame, including about:blank and srcdoc ones that inherit it;
 * the script removes the constructors before the page runs, which is the only way to stop WebRTC.
 */
object PreviewShield {
    /** Every fetch the page makes is intercepted, so allowing only http(s) loses nothing and refuses ws: and wss:. */
    const val POLICY_HEADER = "Content-Security-Policy"
    const val POLICY = "connect-src http: https:"

    private val removed = listOf(
        "WebSocket", "WebTransport", "RTCPeerConnection", "webkitRTCPeerConnection", "RTCDataChannel", "RTCIceCandidate",
    )

    /**
     * Removes the constructors in the page and in any frame it reaches through `contentWindow`, and the service worker
     * registry, since a service worker's own fetches skip the web view client too.
     */
    val documentStartScript: String = buildString {
        append("(function(){var names=[")
        append(removed.joinToString(",") { "\"$it\"" })
        append("];function seal(w){for(var i=0;i<names.length;i++){try{Object.defineProperty(w,names[i],")
        append("{value:undefined,writable:false,configurable:false});}catch(e){}}}seal(window);")
        append("try{Object.defineProperty(Navigator.prototype,\"serviceWorker\",{get:function(){},configurable:false});}catch(e){}")
        append("var d=Object.getOwnPropertyDescriptor(HTMLIFrameElement.prototype,\"contentWindow\");")
        append("if(d&&d.get){Object.defineProperty(HTMLIFrameElement.prototype,\"contentWindow\",")
        append("{get:function(){var w=d.get.call(this);if(w)seal(w);return w;},configurable:false});}})();")
    }

    /** [headers] with the policy added; a policy the page sent stays, and the browser enforces both. */
    fun withPolicy(headers: Map<String, String>): Map<String, String> {
        val existing = headers.entries.firstOrNull { it.key.equals(POLICY_HEADER, ignoreCase = true) }
            ?: return headers + (POLICY_HEADER to POLICY)
        return headers - existing.key + (existing.key to "${existing.value}, $POLICY")
    }
}
