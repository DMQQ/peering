package pl.dmq.peering.imaging

import org.junit.Assert.assertEquals
import org.junit.Test

class ImageSamplingTest {
    @Test
    fun smallPictureIsNotSampled() {
        assertEquals(1, ImageSampling.sampleSize(4_000, 3_000))
    }

    @Test
    fun largePictureIsSampledUnderTheBudget() {
        assertEquals(2, ImageSampling.sampleSize(8_000, 6_000))
        assertEquals(8, ImageSampling.sampleSize(30_000, 30_000))
    }

    @Test
    fun hugeDimensionsDoNotOverflow() {
        assertEquals(1_048_576, ImageSampling.sampleSize(Int.MAX_VALUE, Int.MAX_VALUE))
    }

    @Test
    fun unknownBoundsDoNotSample() {
        assertEquals(1, ImageSampling.sampleSize(0, 0))
    }

    @Test
    fun thumbnailSampleKeepsTheLongSideAtOrAboveTheEdge() {
        assertEquals(4, ImageSampling.sampleForEdge(1_000, 600, 200))
        assertEquals(1, ImageSampling.sampleForEdge(150, 100, 200))
    }
}
