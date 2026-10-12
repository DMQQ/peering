package pl.dmq.peering.platform.video

import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Test
import pl.dmq.peering.wire.VideoCodec
import pl.dmq.peering.wire.VideoStreamConfig

class DecoderRecoveryTest {
    private val config = VideoStreamConfig("display-1", VideoCodec.H264, 1920, 1080, listOf("AAAA"))
    private val other = config.copy(pixelWidth = 1280, pixelHeight = 720)

    @Test
    fun aFatalFailureIsRebuiltUpToTheCapThenGivenUp() {
        val recovery = DecoderRecovery(maxRebuilds = 2)

        assertTrue(recovery.onFatal(config))
        assertTrue(recovery.onFatal(config))
        assertFalse(recovery.onFatal(config))
        assertTrue(recovery.failed)
    }

    @Test
    fun aSustainedRunOfPicturesClearsTheCount() {
        val recovery = DecoderRecovery(maxRebuilds = 1)
        assertTrue(recovery.onFatal(config))

        repeat(DecoderRecovery.SUSTAINED_PICTURES) { recovery.onPictureDecoded() }

        assertTrue(recovery.onFatal(config))
        assertFalse(recovery.failed)
    }

    @Test
    fun aStreamThatDecodesOnePictureThenFailsEveryTimeReachesTheCap() {
        val recovery = DecoderRecovery(maxRebuilds = 3)

        assertTrue(recovery.onFatal(config))
        recovery.onPictureDecoded()
        assertTrue(recovery.onFatal(config))
        recovery.onPictureDecoded()
        assertTrue(recovery.onFatal(config))
        recovery.onPictureDecoded()
        assertFalse(recovery.onFatal(config))
        assertTrue(recovery.failed)
    }

    @Test
    fun theConfigGivenUpOnIsRefusedAgainButAnotherOneIsNot() {
        val recovery = DecoderRecovery(maxRebuilds = 0)
        recovery.onFatal(config)

        assertTrue(recovery.refuses(config))
        assertFalse(recovery.refuses(other))

        recovery.onNewConfig()

        assertFalse(recovery.refuses(config))
        assertFalse(recovery.failed)
    }
}
