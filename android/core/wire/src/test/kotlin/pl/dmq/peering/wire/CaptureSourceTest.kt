package pl.dmq.peering.wire

import kotlinx.serialization.json.JsonObject
import kotlinx.serialization.json.JsonPrimitive
import kotlinx.serialization.json.jsonArray
import kotlinx.serialization.json.jsonObject
import kotlinx.serialization.json.jsonPrimitive
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNotNull
import org.junit.Assert.assertNull
import org.junit.Assert.assertThrows
import org.junit.Assert.assertTrue
import org.junit.Test

class CaptureSourceTest {
    private val builtInDisplayJson = """
        {"id":"display:1","isManagedVirtualDisplay":false,"isVirtualDisplay":false,"kind":"display",
         "pixelSize":[1920,1080],"source":{"display":{"_0":1}},"title":"Built-in"}
    """.trimIndent()

    private fun vectorCatalogText(): String {
        val cases = VectorFiles.load("messages.json").jsonObject.getValue("cases").jsonArray
        return cases.map { it.jsonObject }
            .single { it.getValue("name").jsonPrimitive.content == "catalog displays only" }
            .getValue("json").jsonPrimitive.content
    }

    @Test
    fun displayVectorDecodesToItsStableId() {
        val catalog = CaptureCatalog.parse(vectorCatalogText())
        val display = catalog.displays.single()
        assertEquals("display:1", display.id)
        assertEquals(CaptureSource.Display(1), display.source)
        assertEquals("display:1", display.source.stableId)
        assertEquals(PixelSize(1920.0, 1080.0), display.pixelSize)
        assertFalse(display.isVirtualDisplay)
    }

    @Test
    fun displayDescriptorReEncodesToTheVector() {
        val descriptor = WireJson.decodeFromString(CaptureSourceDescriptor.serializer(), builtInDisplayJson)
        assertTrue(jsonEquals(WireJson.encodeToString(CaptureSourceDescriptor.serializer(), descriptor), builtInDisplayJson))
    }

    @Test
    fun emptyCatalogDecodesWithEveryListEmpty() {
        val catalog = CaptureCatalog.parse("{}")
        assertTrue(catalog.displays.isEmpty())
        assertTrue(catalog.applications.isEmpty())
        assertTrue(catalog.windows.isEmpty())
        assertTrue(catalog.installedApplications.isEmpty())
        assertNull(catalog.spaceInfo)
    }

    @Test
    fun catalogWithOptionalPartsDecodes() {
        val catalog = CaptureCatalog.parse(
            """{"displays":[$builtInDisplayJson],"spaceInfo":{"displays":[]},"installedApplications":[{"name":"x"}]}""",
        )
        assertEquals(1, catalog.displays.size)
        assertEquals(1, catalog.installedApplications.size)
        assertNotNull(catalog.spaceInfo)
    }

    @Test
    fun emptyCatalogWritesAllFourListsAsArrays() {
        val text = CaptureCatalog().toJson()
        assertTrue(jsonEquals(text, """{"displays":[],"applications":[],"windows":[],"installedApplications":[]}"""))
    }

    @Test
    fun catalogWrittenAfterParsingKeepsTheDisplay() {
        val reparsed = CaptureCatalog.parse(CaptureCatalog.parse(vectorCatalogText()).toJson())
        assertEquals("display:1", reparsed.displays.single().id)
    }

    @Test
    fun unknownKeysInsideADescriptorAreIgnored() {
        val withExtra = builtInDisplayJson.replace("\"title\"", "\"futureField\":true,\"title\"")
        val descriptor = WireJson.decodeFromString(CaptureSourceDescriptor.serializer(), withExtra)
        assertEquals("Built-in", descriptor.title)
    }

    @Test
    fun unknownCaptureSourceCaseThrows() {
        val json = """{"bogus":{"_0":1}}"""
        assertThrows(SwiftEnumException::class.java) {
            CaptureSource.fromJson(WireJson.parseToJsonElement(json).jsonObject)
        }
    }

    @Test
    fun badSourceInsideADescriptorThrows() {
        val bad = builtInDisplayJson.replace("""{"display":{"_0":1}}""", """{"bogus":{"_0":1}}""")
        assertThrows(SwiftEnumException::class.java) {
            WireJson.decodeFromString(CaptureSourceDescriptor.serializer(), bad)
        }
    }

    @Test
    fun everySourceCaseHasItsSwiftShape() {
        assertEquals(
            """{"display":{"_0":1}}""",
            WireJson.encodeToString(JsonObject.serializer(), CaptureSource.Display(1).toJson()),
        )
        assertEquals(
            """{"application":{"_0":42}}""",
            WireJson.encodeToString(JsonObject.serializer(), CaptureSource.Application(42).toJson()),
        )
        assertEquals(
            """{"window":{"_0":7}}""",
            WireJson.encodeToString(JsonObject.serializer(), CaptureSource.Window(7).toJson()),
        )
    }

    @Test
    fun sourcesRoundTripThroughTheirJson() {
        val sources = listOf(
            CaptureSource.Display(4294967295L),
            CaptureSource.Application(-1),
            CaptureSource.Window(9),
            CaptureSource.Mosaic(JsonPrimitive("layout")),
        )
        for (source in sources) {
            assertEquals(source, CaptureSource.fromJson(source.toJson()))
        }
    }

    @Test
    fun stableIdsNameEachKind() {
        assertEquals("display:1", CaptureSource.Display(1).stableId)
        assertEquals("application:42", CaptureSource.Application(42).stableId)
        assertEquals("window:7", CaptureSource.Window(7).stableId)
        assertEquals("mosaic", CaptureSource.Mosaic(JsonPrimitive("x")).stableId)
    }

    @Test
    fun pointsAboveOneAndBelowZeroAreClamped() {
        assertEquals(NormalizedPoint(0.0, 1.0), NormalizedPoint(-0.2, 1.5).clamped())
        assertEquals(NormalizedPoint(0.25, 0.75), NormalizedPoint(0.25, 0.75).clamped())
    }

    @Test
    fun notANumberCoordinateClampsToZero() {
        assertEquals(NormalizedPoint(0.0, 0.5), NormalizedPoint(Double.NaN, 0.5).clamped())
    }

    @Test
    fun iconBytesDecodeFromBase64() {
        val withIcon = builtInDisplayJson.replace("\"title\"", "\"iconPNGData\":\"AQI=\",\"title\"")
        val descriptor = WireJson.decodeFromString(CaptureSourceDescriptor.serializer(), withIcon)
        assertTrue(descriptor.iconPNGBytes!!.contentEquals(byteArrayOf(1, 2)))
    }
}
