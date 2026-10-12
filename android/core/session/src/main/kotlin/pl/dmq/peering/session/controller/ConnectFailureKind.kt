package pl.dmq.peering.session.controller

import java.net.ConnectException
import java.net.SocketTimeoutException
import javax.net.ssl.SSLException

/** What went wrong in opening a connection, as far as the exception tells. */
enum class ConnectFailureKind {
    /** No route to the computer, or its name did not resolve. */
    Unreachable,

    /** The computer answered and refused: nothing listens on that port. */
    Refused,

    /** The computer answered but the secure connection could not be set up. */
    TlsFailed,

    /** The computer did not answer in time. */
    Timeout,
    ;

    companion object {
        fun of(failure: Throwable): ConnectFailureKind {
            val chain = causeChain(failure)
            return when {
                chain.any { it is SSLException } -> TlsFailed
                chain.any { it is ConnectException } -> Refused
                chain.any { it is SocketTimeoutException } -> Timeout
                else -> Unreachable
            }
        }

        /** The exception's class and message, and the root cause's when it differs. No payloads, only what the exception says. */
        fun describe(failure: Throwable): String {
            val root = causeChain(failure).last()
            val text = "${failure.javaClass.simpleName}: ${failure.message.orEmpty()}".trimEnd(' ', ':')
            if (root === failure) return text.take(MAX_LENGTH)
            return "$text (caused by ${root.javaClass.simpleName}: ${root.message.orEmpty()})".take(MAX_LENGTH)
        }

        private fun causeChain(failure: Throwable): List<Throwable> =
            generateSequence(failure) { it.cause?.takeIf { cause -> cause !== it } }.take(MAX_DEPTH).toList()

        private const val MAX_LENGTH = 300
        private const val MAX_DEPTH = 8
    }
}
