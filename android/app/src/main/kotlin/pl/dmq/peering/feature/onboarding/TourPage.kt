package pl.dmq.peering.feature.onboarding

import androidx.annotation.DrawableRes
import androidx.annotation.StringRes
import androidx.compose.ui.graphics.vector.ImageVector
import pl.dmq.peering.R
import pl.dmq.peering.ui.kit.AppIcons

internal data class ChipSpec(val symbol: ImageVector, @StringRes val title: Int, val atEnd: Boolean, val y: Float)

internal sealed interface TourContent {
    data class Picture(@DrawableRes val screenshot: Int) : TourContent

    data object Notification : TourContent

    data object Plans : TourContent
}

/** One page of the tour. [companion] is the small phone beside the computer on the first page. */
internal data class TourPage(
    val step: OnboardingStep,
    @StringRes val title: Int,
    @StringRes val body: Int,
    val content: TourContent,
    val chips: List<ChipSpec> = emptyList(),
    @DrawableRes val companion: Int? = null,
    val showsDownload: Boolean = false,
)

internal val tourPages: List<TourPage> = listOf(
    TourPage(
        OnboardingStep.INSTALL, R.string.tour_install_title, R.string.tour_install_body,
        TourContent.Picture(R.drawable.tour_mac), companion = R.drawable.tour_connect, showsDownload = true,
        chips = listOf(
            ChipSpec(AppIcons.checkCircle, R.string.chip_one_time_setup, false, 0.2f),
            ChipSpec(AppIcons.noAccount, R.string.chip_no_account, true, 0.76f),
        ),
    ),
    TourPage(
        OnboardingStep.PAIR, R.string.tour_pair_title, R.string.tour_pair_body, TourContent.Picture(R.drawable.tour_connect),
        chips = listOf(
            ChipSpec(AppIcons.encrypted, R.string.chip_six_digit_code, false, 0.18f),
            ChipSpec(AppIcons.reconnect, R.string.chip_reconnects, true, 0.62f),
        ),
    ),
    TourPage(
        OnboardingStep.SOURCES, R.string.tour_sources_title, R.string.tour_sources_body, TourContent.Picture(R.drawable.tour_sources),
        chips = listOf(
            ChipSpec(AppIcons.display, R.string.chip_whole_display, false, 0.14f),
            ChipSpec(AppIcons.window, R.string.chip_single_window, true, 0.46f),
            ChipSpec(AppIcons.spaces, R.string.chip_any_space, false, 0.76f),
        ),
    ),
    TourPage(
        OnboardingStep.CONTROLS, R.string.tour_controls_title, R.string.tour_controls_body, TourContent.Picture(R.drawable.tour_controls),
        chips = listOf(
            ChipSpec(AppIcons.pointer, R.string.chip_joystick, false, 0.2f),
            ChipSpec(AppIcons.command, R.string.chip_shortcuts, true, 0.5f),
            ChipSpec(AppIcons.observe, R.string.chip_observe, false, 0.78f),
        ),
    ),
    TourPage(
        OnboardingStep.FOLLOWS, R.string.tour_follows_title, R.string.tour_follows_body, TourContent.Picture(R.drawable.tour_pip),
        chips = listOf(
            ChipSpec(AppIcons.pictureInPicture, R.string.chip_pip, false, 0.2f),
            ChipSpec(AppIcons.lockedPhone, R.string.chip_notification, true, 0.62f),
        ),
    ),
    TourPage(
        OnboardingStep.MOSAIC, R.string.tour_mosaic_title, R.string.tour_mosaic_body, TourContent.Picture(R.drawable.tour_mosaic),
        chips = listOf(
            ChipSpec(AppIcons.grid, R.string.chip_live_tiles, true, 0.18f),
            ChipSpec(AppIcons.tap, R.string.chip_tap_to_control, false, 0.66f),
        ),
    ),
    TourPage(
        OnboardingStep.NOTIFICATIONS, R.string.tour_notifications_title, R.string.tour_notifications_body, TourContent.Notification,
        chips = listOf(
            ChipSpec(AppIcons.lockedPhone, R.string.chip_lock_screen, false, 0.12f),
            ChipSpec(AppIcons.notification, R.string.chip_app_closed, true, 0.5f),
        ),
    ),
    TourPage(OnboardingStep.PLANS, R.string.tour_plans_title, R.string.tour_plans_body, TourContent.Plans),
)
