package pl.dmq.peering.ui

import java.io.File
import org.junit.Assert.assertTrue
import org.junit.Test

/**
 * Corner radii are chosen once, in the theme's shape scheme. A component that writes its own `RoundedCornerShape`
 * or `CutCornerShape` drifts from the scheme. The allow-list holds drawings that scale with a device, not UI.
 */
class ShapeLiteralScanTest {
    private val allowed = mapOf(
        "ui/theme/PeeringShapes.kt" to "the scheme itself",
        "ui/theme/IconTile.kt" to "an app icon tile whose radius is a fraction of its size",
        "ui/kit/DeviceFrames.kt" to "hardware drawings scaled from a width",
        "feature/onboarding/NotificationBanner.kt" to "a drawing of a system notification scaled from a width",
    )
    private val literal = Regex("""\b(RoundedCornerShape|CutCornerShape|AbsoluteRoundedCornerShape)\s*\(""")

    @Test
    fun noComponentHardCodesACornerRadius() {
        val root = File("src/main/kotlin")
        assertTrue("run from the app module: ${root.absolutePath}", root.isDirectory)
        val offences = root.walkTopDown()
            .filter { it.isFile && it.extension == "kt" && it.relativeTo(File("src/main/kotlin/pl/dmq/peering")).path !in allowed }
            .flatMap { file ->
                file.readLines().mapIndexedNotNull { i, line ->
                    if (literal.containsMatchIn(line)) "${file.relativeTo(root).path}:${i + 1}  ${line.trim()}" else null
                }
            }
            .toList()
        assertTrue("use MaterialTheme.shapes or PillShape instead:\n" + offences.joinToString("\n"), offences.isEmpty())
    }
}
