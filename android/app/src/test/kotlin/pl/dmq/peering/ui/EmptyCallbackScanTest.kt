package pl.dmq.peering.ui

import java.io.File
import org.junit.Assert.assertTrue
import org.junit.Test

/**
 * A callback nobody wired compiles and then does nothing when tapped. Production code may not contain an empty lambda
 * (`{}`, `{ }`, `{ _ -> }`) or a TODO call. The allow-list is empty on purpose: add an entry only with the reason a
 * given file:line cannot do without one.
 */
class EmptyCallbackScanTest {
    private val allowed: Map<String, String> = emptyMap()

    private val emptyLambda = Regex("""\{\s*(\w+(\s*,\s*\w+)*\s*->\s*)?\}""")
    private val todoCall = Regex("""\bTODO\s*\(""")

    @Test
    fun productionCodeHasNoEmptyCallbacksOrTodos() {
        val root = File("src/main/kotlin")
        assertTrue("run from the app module: ${root.absolutePath}", root.isDirectory)
        val offences = root.walkTopDown()
            .filter { it.isFile && it.extension == "kt" }
            .flatMap { file -> offencesIn(file, root) }
            .filterNot { it.substringBefore(" ") in allowed }
            .toList()
        assertTrue("empty callbacks or TODOs:\n" + offences.joinToString("\n"), offences.isEmpty())
    }

    @Test
    fun theScannerSeesEachShapeItIsMeantToCatch() {
        val sample = "a(onClick = {})\nb({ })\nc { _ -> }\nd { x, y -> }\nTODO(\"later\")\nval ok = { 1 }"
        val hits = scan(sample).map { it.first }
        assertTrue(hits == listOf(1, 2, 3, 4, 5))
    }

    private fun offencesIn(file: File, root: File): List<String> =
        scan(file.readText()).map { (line, text) -> "${file.relativeTo(root).path}:$line  $text" }

    private fun scan(source: String): List<Pair<Int, String>> {
        val code = withoutStringsAndComments(source)
        val lines = code.lines()
        return lines.mapIndexedNotNull { index, line ->
            if (emptyLambda.containsMatchIn(line) || todoCall.containsMatchIn(line)) (index + 1) to line.trim() else null
        } + multiLine(code, lines)
    }

    private fun multiLine(code: String, lines: List<String>): List<Pair<Int, String>> =
        emptyLambda.findAll(code)
            .filter { '\n' in it.value }
            .map { match -> (code.substring(0, match.range.first).count { it == '\n' } + 1) to lines[code.substring(0, match.range.first).count { it == '\n' }].trim() }
            .toList()

    private fun withoutStringsAndComments(source: String): String {
        val noStrings = source.replace(Regex(""""(\\.|[^"\\\n])*""""), "\"\"")
        val noBlocks = Regex("""/\*[\s\S]*?\*/""").replace(noStrings) { it.value.replace(Regex("[^\n]"), " ") }
        return noBlocks.replace(Regex("""//[^\n]*"""), "")
    }
}
