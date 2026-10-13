package pl.dmq.peering.feature.remote

import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.flow.Flow
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.StateFlow
import kotlinx.coroutines.flow.flowOf
import kotlinx.coroutines.test.UnconfinedTestDispatcher
import org.junit.Assert.assertEquals
import org.junit.Assert.assertTrue
import org.junit.Test
import pl.dmq.peering.feature.settings.StreamQuality
import pl.dmq.peering.session.controller.QualityChoice
import pl.dmq.peering.wire.QualityTier

class QualitySheetPresenterTest {
    private class FakeQualityPort(
        ceiling: QualityTier,
        private val saves: Boolean = true,
    ) : QualityPort {
        override val stored: Flow<StreamQuality> = flowOf(StreamQuality.Auto)
        private val mutableCeiling = MutableStateFlow(ceiling)
        override val ceiling: StateFlow<QualityTier> = mutableCeiling
        val saved = mutableListOf<StreamQuality>()
        val applied = mutableListOf<QualityChoice>()

        override fun saveDefault(quality: StreamQuality): Boolean {
            saved += quality
            return saves
        }

        override fun apply(choice: QualityChoice): Boolean {
            applied += choice
            return true
        }
    }

    private fun presenter(port: QualityPort, onUpgrade: () -> Unit = {}) =
        QualitySheetPresenter(port, CoroutineScope(UnconfinedTestDispatcher()), onUpgrade)

    @Test
    fun aFixedLevelIsStoredAsTheDefaultAndApplied() {
        val port = FakeQualityPort(QualityTier.HIGH)
        presenter(port).choose(StreamQuality.Low)
        assertEquals(listOf(StreamQuality.Low), port.saved)
        assertEquals(listOf<QualityChoice>(QualityChoice.Fixed(QualityTier.LOW)), port.applied)
    }

    @Test
    fun aLevelAboveARelayCeilingOpensTheUpgradeAndChangesNothing() {
        val port = FakeQualityPort(QualityTier.MEDIUM)
        var upgrades = 0
        presenter(port) { upgrades++ }.choose(StreamQuality.High)
        assertEquals(1, upgrades)
        assertTrue(port.saved.isEmpty())
        assertTrue(port.applied.isEmpty())
    }

    @Test
    fun aDefaultThatDoesNotPersistIsNotApplied() {
        val port = FakeQualityPort(QualityTier.HIGH, saves = false)
        val sheet = presenter(port)
        sheet.choose(StreamQuality.Medium)
        assertTrue(port.applied.isEmpty())
        assertTrue(sheet.ui.value.saveFailed)
    }

    @Test
    fun autoIsAppliedAsThePolicyChoice() {
        val port = FakeQualityPort(QualityTier.MEDIUM)
        presenter(port).choose(StreamQuality.Auto)
        assertEquals(listOf<QualityChoice>(QualityChoice.Automatic), port.applied)
    }

    @Test
    fun theSheetShowsTheCeilingTheSessionIsHeldTo() {
        val port = FakeQualityPort(QualityTier.MEDIUM)
        assertEquals(QualityTier.MEDIUM, presenter(port).ui.value.ceiling)
    }
}
