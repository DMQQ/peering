package pl.dmq.peering.wire

import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Test

class TrackpadModelTest {
    private fun model(sensitivity: Double = 1.0) = TrackpadModel(1000.0, 800.0, sensitivity)

    @Test
    fun oneFingerDragMovesTheCursorByTheDeltaOverTheCanvasWidth() {
        val trackpad = model()
        trackpad.onDown(1, 100.0, 100.0, 0)
        assertEquals(listOf(PointerAction.MoveTo(0.75, 0.5)), trackpad.onMove(1, 350.0, 100.0, 50))
    }

    @Test
    fun aFullWidthSwipeAtDefaultSensitivityCrossesTheWholeCanvas() {
        val trackpad = model()
        trackpad.onDown(1, 0.0, 0.0, 0)
        trackpad.onMove(1, 500.0, 0.0, 50)
        assertEquals(listOf(PointerAction.MoveTo(1.0, 0.5)), trackpad.onMove(1, 1000.0, 0.0, 100))
    }

    @Test
    fun sensitivityScalesTheCursorMovement() {
        val trackpad = model(sensitivity = 2.0)
        trackpad.onDown(1, 100.0, 100.0, 0)
        assertEquals(listOf(PointerAction.MoveTo(0.75, 0.5)), trackpad.onMove(1, 225.0, 100.0, 50))
    }

    @Test
    fun theCursorIsClampedToTheCanvas() {
        val trackpad = model()
        trackpad.onDown(1, 900.0, 100.0, 0)
        assertEquals(listOf(PointerAction.MoveTo(1.0, 0.0)), trackpad.onMove(1, 1900.0, -5000.0, 50))
    }

    @Test
    fun aQuickSmallTapClicksTheLeftButton() {
        val trackpad = model()
        trackpad.onDown(1, 100.0, 100.0, 0)
        assertEquals(listOf(PointerAction.Click(MouseButton.LEFT)), trackpad.onUp(1, 100.0, 100.0, 200))
    }

    @Test
    fun aTapLongerThanTwoHundredFiftyMillisecondsIsNotAClick() {
        val trackpad = model()
        trackpad.onDown(1, 100.0, 100.0, 0)
        assertEquals(emptyList<PointerAction>(), trackpad.onUp(1, 100.0, 100.0, 300))
    }

    @Test
    fun aFingerThatTravelledMoreThanTenPixelsIsNotATap() {
        val trackpad = model()
        trackpad.onDown(1, 100.0, 100.0, 0)
        trackpad.onMove(1, 130.0, 100.0, 50)
        assertEquals(emptyList<PointerAction>(), trackpad.onUp(1, 130.0, 100.0, 100))
    }

    @Test
    fun aFingerThatWanderedAndCameBackIsNotATap() {
        val trackpad = model()
        trackpad.onDown(1, 100.0, 100.0, 0)
        trackpad.onMove(1, 115.0, 100.0, 50)
        trackpad.onMove(1, 100.0, 100.0, 80)
        assertEquals(emptyList<PointerAction>(), trackpad.onUp(1, 100.0, 100.0, 100))
    }

    @Test
    fun aTwoFingerTapClicksTheRightButton() {
        val trackpad = model()
        trackpad.onDown(1, 100.0, 100.0, 0)
        trackpad.onDown(2, 300.0, 100.0, 50)
        assertEquals(emptyList<PointerAction>(), trackpad.onUp(1, 100.0, 100.0, 100))
        assertEquals(listOf(PointerAction.Click(MouseButton.RIGHT)), trackpad.onUp(2, 300.0, 100.0, 120))
    }

    @Test
    fun aTwoFingerDragScrollsByTheFingerDelta() {
        val trackpad = model()
        trackpad.onDown(1, 100.0, 100.0, 0)
        trackpad.onDown(2, 300.0, 100.0, 0)
        assertEquals(listOf(PointerAction.Scroll(0.0, 30.0)), trackpad.onMove(1, 100.0, 130.0, 100))
    }

    @Test
    fun aTwoFingerDragDoesNotMoveTheCursor() {
        val trackpad = model()
        trackpad.onDown(1, 100.0, 100.0, 0)
        trackpad.onDown(2, 300.0, 100.0, 0)
        trackpad.onMove(2, 300.0, 160.0, 100)
        assertEquals(0.5, trackpad.cursorX, 0.0)
        assertEquals(0.5, trackpad.cursorY, 0.0)
    }

    @Test
    fun aTwoFingerDragIsNotAClickWhenItLifts() {
        val trackpad = model()
        trackpad.onDown(1, 100.0, 100.0, 0)
        trackpad.onDown(2, 300.0, 100.0, 0)
        trackpad.onMove(1, 100.0, 160.0, 100)
        assertEquals(emptyList<PointerAction>(), trackpad.onUp(1, 100.0, 160.0, 120))
        assertEquals(emptyList<PointerAction>(), trackpad.onUp(2, 300.0, 100.0, 130))
    }

    @Test
    fun aLongPressFollowedByAMoveStartsADrag() {
        val trackpad = model()
        trackpad.onDown(1, 100.0, 100.0, 0)
        assertEquals(
            listOf(PointerAction.ButtonDown(MouseButton.LEFT), PointerAction.MoveTo(0.75, 0.5)),
            trackpad.onMove(1, 350.0, 100.0, 450),
        )
    }

    @Test
    fun aDragEndsWithALeftButtonUpAndNoClick() {
        val trackpad = model()
        trackpad.onDown(1, 100.0, 100.0, 0)
        trackpad.onMove(1, 350.0, 100.0, 450)
        assertEquals(listOf(PointerAction.ButtonUp(MouseButton.LEFT)), trackpad.onUp(1, 350.0, 100.0, 500))
    }

    @Test
    fun aLongPressWithNoMoveIsNothing() {
        val trackpad = model()
        trackpad.onDown(1, 100.0, 100.0, 0)
        assertEquals(emptyList<PointerAction>(), trackpad.onUp(1, 100.0, 100.0, 500))
    }

    @Test
    fun aMoveBeforeTheHoldTimeDoesNotStartADrag() {
        val trackpad = model()
        trackpad.onDown(1, 100.0, 100.0, 0)
        val early = trackpad.onMove(1, 150.0, 100.0, 100)
        assertFalse(early.any { it is PointerAction.ButtonDown })
        val later = trackpad.onMove(1, 200.0, 100.0, 500)
        assertFalse(later.any { it is PointerAction.ButtonDown })
    }

    @Test
    fun aSecondFingerEndsADragWithALeftButtonUp() {
        val trackpad = model()
        trackpad.onDown(1, 100.0, 100.0, 0)
        trackpad.onMove(1, 350.0, 100.0, 450)
        assertEquals(listOf(PointerAction.ButtonUp(MouseButton.LEFT)), trackpad.onDown(2, 500.0, 100.0, 460))
    }

    @Test
    fun directModeMapsCanvasPixelsToAbsolutePoints() {
        val trackpad = model()
        assertEquals(
            listOf(PointerAction.MoveTo(0.5, 0.5), PointerAction.ButtonDown(MouseButton.LEFT)),
            trackpad.onDirectDown(500.0, 400.0),
        )
        assertEquals(listOf(PointerAction.MoveTo(0.75, 0.25)), trackpad.onDirectMove(750.0, 200.0))
        assertEquals(
            listOf(PointerAction.MoveTo(0.75, 0.25), PointerAction.ButtonUp(MouseButton.LEFT)),
            trackpad.onDirectUp(750.0, 200.0),
        )
    }

    @Test
    fun directModeClampsPointsOutsideTheCanvas() {
        val trackpad = model()
        assertEquals(listOf(PointerAction.MoveTo(0.0, 1.0)), trackpad.onDirectMove(-50.0, 2000.0))
    }

    @Test
    fun aSampleFromAnUnknownPointerIsIgnored() {
        val trackpad = model()
        assertTrue(trackpad.onMove(9, 10.0, 10.0, 0).isEmpty())
        assertTrue(trackpad.onUp(9, 10.0, 10.0, 0).isEmpty())
    }

    @Test
    fun theVerticalMoveIsScaledByTheHeightNotTheWidth() {
        val trackpad = model()
        trackpad.onDown(1, 100.0, 100.0, 0)
        assertEquals(listOf(PointerAction.MoveTo(0.5, 0.75)), trackpad.onMove(1, 100.0, 300.0, 50))
    }

    @Test
    fun sweepSetsThePixelsAFingerCrossesToSpanThePicture() {
        val trackpad = model()
        trackpad.sweep(500.0, 250.0)
        trackpad.onDown(1, 0.0, 0.0, 0)
        assertEquals(listOf(PointerAction.MoveTo(0.6, 0.6)), trackpad.onMove(1, 50.0, 25.0, 50))
    }

    @Test
    fun syncingTheCursorStartsTheNextDragFromThere() {
        val trackpad = model()
        trackpad.syncCursor(0.25, 0.5)
        trackpad.onDown(1, 100.0, 100.0, 0)
        assertEquals(listOf(PointerAction.MoveTo(0.35, 0.5)), trackpad.onMove(1, 200.0, 100.0, 50))
    }
}
