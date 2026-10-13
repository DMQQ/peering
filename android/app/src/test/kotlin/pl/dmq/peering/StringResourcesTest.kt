package pl.dmq.peering

import org.junit.Assert.assertEquals
import org.junit.Assert.assertTrue
import org.junit.Test
import org.w3c.dom.Element
import java.io.File
import javax.xml.parsers.DocumentBuilderFactory

/**
 * Every locale directory under res/ is held to the English files: same keys, same placeholders, the plural quantities
 * the language needs, no dashes of the em or en kind, no empty values. It walks whatever directories exist, so a
 * language is checked from the moment its folder lands.
 *
 * Directory names, fixed so every translator uses the same ones:
 * values-de, values-es, values-fr, values-it, values-ja, values-ko, values-pt-rBR, values-ru, values-b+zh+Hans.
 * Files mirror the English ones (strings.xml, strings_ssh.xml, ...); only the keys across them matter to this test.
 */
class StringResourcesTest {
    private sealed interface Entry {
        data class Text(val value: String) : Entry
        data class Plural(val items: Map<String, String>) : Entry
        data class Array(val items: List<String>) : Entry
    }

    private val res = File("src/main/res")

    /** Directory suffix to the language tag it holds, as listed in xml/locales_config.xml. */
    private val locales = mapOf(
        "values-de" to "de",
        "values-es" to "es",
        "values-fr" to "fr",
        "values-it" to "it",
        "values-ja" to "ja",
        "values-ko" to "ko",
        "values-pt-rBR" to "pt-BR",
        "values-ru" to "ru",
        "values-b+zh+Hans" to "zh-Hans",
    )

    /** CLDR cardinal categories a language must provide. Lint and the runtime fall back to "other" for any missing one. */
    private val requiredQuantities = mapOf(
        "en" to setOf("one", "other"),
        "de" to setOf("one", "other"),
        "es" to setOf("one", "other"),
        "fr" to setOf("one", "other"),
        "it" to setOf("one", "other"),
        "pt-BR" to setOf("one", "other"),
        "ru" to setOf("one", "few", "many", "other"),
        "ja" to setOf("other"),
        "ko" to setOf("other"),
        "zh-Hans" to setOf("other"),
    )

    /** "many" is optional in the Romance languages (CLDR uses it for millions only). */
    private val allowedQuantities = requiredQuantities.toMutableMap().apply {
        for (tag in listOf("es", "fr", "it", "pt-BR")) put(tag, getValue(tag) + "many")
    }

    private val placeholder = Regex("%(?:\\d+\\$)?[-#+ 0,(]*\\d*(?:\\.\\d+)?[a-zA-Z]")

    private fun placeholders(text: String): List<String> =
        placeholder.findAll(text.replace("%%", "")).map { it.value.last().toString() }.sorted().toList()

    private fun load(dir: File, translatableOnly: Boolean): Map<String, Entry> {
        val out = linkedMapOf<String, Entry>()
        val files = dir.listFiles { file -> file.name.startsWith("strings") && file.name.endsWith(".xml") }.orEmpty().sortedBy { it.name }
        for (file in files) {
            val root = DocumentBuilderFactory.newInstance().newDocumentBuilder().parse(file).documentElement
            val nodes = root.childNodes
            for (index in 0 until nodes.length) {
                val node = nodes.item(index) as? Element ?: continue
                if (translatableOnly && node.getAttribute("translatable") == "false") continue
                val name = node.getAttribute("name")
                val entry = when (node.tagName) {
                    "string" -> Entry.Text(node.textContent)
                    "plurals" -> Entry.Plural(items(node).associate { it.getAttribute("quantity") to it.textContent })
                    "string-array" -> Entry.Array(items(node).map { it.textContent })
                    else -> error("${file.name}: unexpected <${node.tagName}>")
                }
                assertTrue("${dir.name}/${file.name}: duplicate key $name", out.put(name, entry) == null)
            }
        }
        return out
    }

    private fun items(parent: Element): List<Element> {
        val list = parent.getElementsByTagName("item")
        return (0 until list.length).map { list.item(it) as Element }
    }

    private fun localeDirectories(): List<File> =
        res.listFiles { file -> file.isDirectory && file.name in locales }.orEmpty().sortedBy { it.name }

    private fun allTexts(entry: Entry): List<String> = when (entry) {
        is Entry.Text -> listOf(entry.value)
        is Entry.Plural -> entry.items.values.toList()
        is Entry.Array -> entry.items
    }

    @Test
    fun noValuesDirectoryIsAnUnknownLocale() {
        val known = locales.keys + setOf("values")
        val stray = res.listFiles { file -> file.isDirectory && file.name.startsWith("values") && file.name !in known }.orEmpty()
            .filter { dir -> dir.listFiles { f -> f.name.startsWith("strings") }.orEmpty().isNotEmpty() }
        assertTrue("strings in a directory this test does not know: ${stray.map { it.name }}", stray.isEmpty())
    }

    @Test
    fun englishIsCompleteAndClean() {
        val english = load(File(res, "values"), translatableOnly = false)
        assertTrue(english.isNotEmpty())
        for ((name, entry) in english) {
            if (entry is Entry.Plural) {
                val missing = requiredQuantities.getValue("en") - entry.items.keys
                assertTrue("en: $name lacks $missing", missing.isEmpty())
            }
            checkTexts("en", name, entry)
        }
    }

    @Test
    fun everyLocaleHasExactlyTheEnglishKeys() {
        val english = load(File(res, "values"), translatableOnly = true)
        for (dir in localeDirectories()) {
            val translated = load(dir, translatableOnly = false)
            val missing = english.keys - translated.keys
            val extra = translated.keys - english.keys
            assertTrue("${dir.name}: ${missing.size} keys missing, first: ${missing.take(8)}", missing.isEmpty())
            assertTrue("${dir.name}: keys English does not translate: ${extra.take(8)}", extra.isEmpty())
        }
    }

    @Test
    fun everyLocaleKeepsTheKindAndPlaceholdersOfEnglish() {
        val english = load(File(res, "values"), translatableOnly = true)
        for (dir in localeDirectories()) {
            val tag = locales.getValue(dir.name)
            for ((name, entry) in load(dir, translatableOnly = false)) {
                val source = english[name] ?: continue
                val where = "${dir.name}: $name"
                when (entry) {
                    is Entry.Text -> {
                        assertTrue("$where is not a plain string in English", source is Entry.Text)
                        assertEquals("$where placeholders", placeholders((source as Entry.Text).value), placeholders(entry.value))
                    }
                    is Entry.Plural -> {
                        assertTrue("$where is not a plurals in English", source is Entry.Plural)
                        checkPlural(tag, where, (source as Entry.Plural).items, entry.items)
                    }
                    is Entry.Array -> {
                        assertTrue("$where is not an array in English", source is Entry.Array)
                        val sourceItems = (source as Entry.Array).items
                        assertEquals("$where item count", sourceItems.size, entry.items.size)
                        sourceItems.indices.forEach { assertEquals("$where item $it", placeholders(sourceItems[it]), placeholders(entry.items[it])) }
                    }
                }
            }
        }
    }

    private fun checkPlural(tag: String, where: String, source: Map<String, String>, translated: Map<String, String>) {
        val missing = requiredQuantities.getValue(tag) - translated.keys
        val extra = translated.keys - allowedQuantities.getValue(tag)
        assertTrue("$where lacks quantities $missing", missing.isEmpty())
        assertTrue("$where has quantities $extra that $tag does not use", extra.isEmpty())
        val fromOther = placeholders(source.getValue("other"))
        for ((quantity, text) in translated) {
            val allowed = buildSet {
                add(fromOther)
                if (tag != "ru") source[quantity]?.let { add(placeholders(it)) }
            }
            assertTrue("$where[$quantity] placeholders ${placeholders(text)} not in $allowed", placeholders(text) in allowed)
        }
    }

    @Test
    fun everyLocaleIsFreeOfDashesAndEmptyValues() {
        for (dir in localeDirectories()) {
            for ((name, entry) in load(dir, translatableOnly = false)) checkTexts(dir.name, name, entry)
        }
    }

    private fun checkTexts(where: String, name: String, entry: Entry) {
        for (text in allTexts(entry)) {
            assertTrue("$where: $name is empty", text.isNotBlank())
            assertTrue("$where: $name has an em or en dash: $text", '—' !in text && '–' !in text)
        }
    }

    @Test
    fun theLocaleConfigListsEveryTranslation() {
        val config = File(res, "xml/locales_config.xml").readText()
        val listed = Regex("android:name=\"([^\"]+)\"").findAll(config).map { it.groupValues[1] }.toSet()
        assertTrue("en is the source language", "en" in listed)
        for (dir in localeDirectories()) {
            assertTrue("${dir.name} is translated but not in locales_config.xml", locales.getValue(dir.name) in listed)
        }
    }
}
