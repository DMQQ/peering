package pl.dmq.peering.feature.agents.preview

import android.annotation.SuppressLint
import android.content.Context
import android.graphics.Bitmap
import android.webkit.WebResourceError
import android.webkit.WebResourceRequest
import android.webkit.WebResourceResponse
import android.webkit.WebSettings
import android.webkit.WebView
import android.webkit.WebViewClient
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.SupervisorJob
import kotlinx.coroutines.cancel
import pl.dmq.peering.wire.PreviewFailure

/**
 * The web view behind the preview screen. Every request for a loopback address is answered by [handler] through the
 * computer, so none reaches the phone's own network; the page cache is off, so a reload shows what the server has now.
 */
@SuppressLint("SetJavaScriptEnabled")
class PreviewWeb(context: Context, private val presenter: PreviewPresenter, fetch: PreviewFetch) {
    private val scope = CoroutineScope(SupervisorJob() + Dispatchers.IO)
    private val handler = PreviewRequestHandler(fetch, scope, presenter::pageFailed)

    val view: WebView = WebView(context).apply {
        settings.javaScriptEnabled = true
        settings.domStorageEnabled = true
        settings.cacheMode = WebSettings.LOAD_NO_CACHE
        settings.allowFileAccess = false
        settings.allowContentAccess = false
        settings.setSupportMultipleWindows(false)
        setBackgroundColor(TRANSPARENT)
        webViewClient = Client()
    }

    val canGoBack: Boolean get() = view.canGoBack()

    fun load(url: String) = view.loadUrl(url)

    fun reload() {
        val url = view.url
        if (url == null || url == ABOUT_BLANK) return
        view.loadUrl(url)
    }

    fun goBack() = view.goBack()

    fun close() {
        scope.cancel()
        view.stopLoading()
        view.destroy()
    }

    private inner class Client : WebViewClient() {
        override fun shouldInterceptRequest(view: WebView, request: WebResourceRequest): WebResourceResponse? {
            val reply = handler.handle(request.url.toString(), request.method, request.requestHeaders, request.isForMainFrame) ?: return null
            return WebResourceResponse(reply.mimeType, reply.charset, reply.status, reply.reason, reply.headers, reply.body)
        }

        override fun shouldOverrideUrlLoading(view: WebView, request: WebResourceRequest): Boolean =
            presenter.navigation(request.url.toString()) == NavigationDecision.Block

        override fun onPageStarted(view: WebView, url: String?, favicon: Bitmap?) = presenter.pageStarted()

        override fun onPageFinished(view: WebView, url: String?) = presenter.pageFinished(url, view.canGoBack())

        override fun onReceivedError(view: WebView, request: WebResourceRequest, error: WebResourceError) {
            if (request.isForMainFrame) presenter.pageFailed(PreviewFailure.FAILED)
        }
    }

    private companion object {
        const val TRANSPARENT = 0
        const val ABOUT_BLANK = "about:blank"
    }
}
