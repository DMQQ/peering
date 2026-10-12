package pl.dmq.peering.feature.agents

import java.time.ZoneId
import org.junit.Assert.assertEquals
import org.junit.Assert.assertNotEquals
import org.junit.Test
import pl.dmq.peering.feature.agents.attach.PhotoName

class PhotoNameTest {
    @Test
    fun aPhotoIsNamedForTheMomentItWasPicked() {
        assertEquals("Photo-20261012-134501.jpg", PhotoName.of(1_791_812_701_000L, ZoneId.of("UTC")))
    }

    @Test
    fun twoPhotosASecondApartDoNotShareAName() {
        assertNotEquals(PhotoName.of(1_000_000_000_000L, ZoneId.of("UTC")), PhotoName.of(1_000_000_001_000L, ZoneId.of("UTC")))
    }
}
