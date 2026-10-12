package pl.dmq.peering.feature.paywall

import org.junit.Assert.assertEquals
import org.junit.Test

class RemainingLabelTest {
    @Test
    fun noTimeLeftIsNone() {
        assertEquals(RemainingLabel.None, RemainingLabel.of(0))
        assertEquals(RemainingLabel.None, RemainingLabel.of(-30))
    }

    @Test
    fun underAMinuteIsNotRoundedUpToAMinute() {
        assertEquals(RemainingLabel.UnderAMinute, RemainingLabel.of(59))
    }

    @Test
    fun minutesRoundDownSoTheLabelNeverPromisesMoreThanIsLeft() {
        assertEquals(RemainingLabel.Minutes(1), RemainingLabel.of(60))
        assertEquals(RemainingLabel.Minutes(29), RemainingLabel.of(1_799))
        assertEquals(RemainingLabel.Minutes(59), RemainingLabel.of(3_599))
    }

    @Test
    fun hoursAreSplitFromTheMinutesLeftOver() {
        assertEquals(RemainingLabel.HoursAndMinutes(1, 0), RemainingLabel.of(3_600))
        assertEquals(RemainingLabel.HoursAndMinutes(2, 5), RemainingLabel.of(7_500))
    }
}
