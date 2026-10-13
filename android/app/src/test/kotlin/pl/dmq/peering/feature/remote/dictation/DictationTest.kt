package pl.dmq.peering.feature.remote.dictation

import org.junit.Assert.assertEquals
import org.junit.Assert.assertTrue
import org.junit.Test
import kotlin.math.pow

class DictationTest {
    @Test
    fun silenceDrawsNoBar() {
        assertEquals(0f, DictationLevels.levelForDecibels(-80f), 0f)
        assertEquals(0f, DictationLevels.levelForDecibels(Float.NEGATIVE_INFINITY), 0f)
        assertEquals(0f, DictationLevels.levelForDecibels(DictationLevels.FLOOR_DECIBELS), 0f)
    }

    @Test
    fun loudSpeechFillsTheBar() {
        assertEquals(1f, DictationLevels.levelForDecibels(0f), 0f)
        assertEquals(1f, DictationLevels.levelForDecibels(10f), 0f)
    }

    @Test
    fun aQuieterVoiceDrawsASmallerBar() {
        assertTrue(DictationLevels.levelForDecibels(-30f) < DictationLevels.levelForDecibels(-10f))
    }

    @Test
    fun theCurveIsAPowerOfOnePointSixOverTheSpanFromTheFloor() {
        assertEquals(0.25.pow(1.6).toFloat(), DictationLevels.levelForDecibels(-37.5f), 1e-5f)
    }

    @Test
    fun theRecogniserScaleReachesBothEnds() {
        assertEquals(0f, DictationLevels.levelForRms(-2f), 0f)
        assertEquals(1f, DictationLevels.levelForRms(10f), 0f)
        assertTrue(DictationLevels.levelForRms(4f) in 0.05f..0.95f)
    }

    @Test
    fun theNewestLevelIsLastAndTheCountStaysFixed() {
        val levels = DictationLevels().added(10f)
        assertEquals(DictationLevels.BAR_COUNT, levels.bars.size)
        assertEquals(1f, levels.bars.last(), 0f)
        assertEquals(0f, levels.bars.first(), 0f)
    }

    @Test
    fun spokenTextIsSeparatedFromAWordBeforeIt() {
        assertEquals(" -la", DictationText.insertion("ls", " -la "))
        assertEquals("-la", DictationText.insertion("ls ", "-la"))
        assertEquals("hello", DictationText.insertion("", "hello"))
        assertEquals("", DictationText.insertion("ls", "  "))
    }

    @Test
    fun phrasesJoinWithOneSpaceAndThePartialFollows() {
        val heard = DictationTranscript().withFinished("hello there").withPartial(" how are")
        assertEquals("hello there how are", heard.text)
        assertEquals("hello there how are you", heard.withFinished("how are you").text)
    }

    @Test
    fun aBlankFinalResultKeepsTheWordsAlreadyShown() {
        assertEquals("almost", DictationTranscript().withPartial("almost").withFinished("").text)
    }

    @Test
    fun nothingHeardIsEmpty() {
        assertEquals("", DictationTranscript().text)
    }
}
