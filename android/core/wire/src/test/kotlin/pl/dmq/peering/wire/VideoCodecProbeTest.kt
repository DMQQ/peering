package pl.dmq.peering.wire

import org.junit.Assert.assertEquals
import org.junit.Test

class VideoCodecProbeTest {
    @Test
    fun hevcComesFirstWhenBothAreDecodable() {
        assertEquals(listOf("hevc", "h264"), VideoCodecProbe.codecPreference(listOf("video/avc", "video/hevc")))
    }

    @Test
    fun onlyAvcMapsToH264() {
        assertEquals(listOf("h264"), VideoCodecProbe.codecPreference(listOf("video/avc")))
    }

    @Test
    fun onlyHevcMapsToHevc() {
        assertEquals(listOf("hevc"), VideoCodecProbe.codecPreference(setOf("video/hevc")))
    }

    @Test
    fun unrelatedTypesAreIgnored() {
        assertEquals(emptyList<String>(), VideoCodecProbe.codecPreference(listOf("video/x-vnd.on2.vp9", "audio/mp4a-latm")))
    }

    @Test
    fun mimeTypesMatchWhateverTheirCase() {
        assertEquals(listOf("hevc", "h264"), VideoCodecProbe.codecPreference(listOf("Video/AVC", "VIDEO/HEVC")))
    }

    @Test
    fun aDecoderListWithNoTypesGivesNoPreference() {
        assertEquals(emptyList<String>(), VideoCodecProbe.codecPreference(emptyList()))
    }
}
