package pl.dmq.peering.debug

import android.content.BroadcastReceiver
import android.content.Context
import android.content.Intent
import android.util.Log
import pl.dmq.peering.testing.TestBridge

/**
 * The debug build's way in for an end to end run from a shell:
 * `adb shell am broadcast -a pl.dmq.peering.debug.CMD -n pl.dmq.peering/.debug.DebugCommandReceiver --es cmd tab --es arg sessions`.
 * Results go to logcat: the state dump under PEERTEST, one acknowledgement per command under PEERCMD.
 */
class DebugCommandReceiver : BroadcastReceiver() {
    override fun onReceive(context: Context, intent: Intent) {
        val cmd = intent.getStringExtra("cmd")
        val arg = intent.getStringExtra("arg")
        when (val parsed = DebugCommand.parse(cmd, arg)) {
            DebugCommand.Dump -> Log.i(DUMP_TAG, DumpJson.render(TestBridge.snapshot()))
            is DebugCommand.Invalid -> Log.w(ACK_TAG, "rejected $cmd: ${parsed.reason}")
            is DebugCommand.Run -> {
                val handled = try {
                    (parsed.action == "back" && TestBridge.invoke("hub-back", null)) || TestBridge.invoke(parsed.action, parsed.argument)
                } catch (failure: RuntimeException) {
                    Log.e(ACK_TAG, "${parsed.action} failed", failure)
                    return
                }
                Log.i(ACK_TAG, if (handled) "ran ${parsed.action} ${parsed.argument.orEmpty()}" else "unsupported ${parsed.action}")
            }
        }
    }

    private companion object {
        const val DUMP_TAG = "PEERTEST"
        const val ACK_TAG = "PEERCMD"
    }
}
