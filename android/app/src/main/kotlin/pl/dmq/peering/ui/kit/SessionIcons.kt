package pl.dmq.peering.ui.kit

import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.automirrored.outlined.Backspace
import androidx.compose.material.icons.automirrored.outlined.KeyboardArrowLeft
import androidx.compose.material.icons.automirrored.outlined.KeyboardReturn
import androidx.compose.material.icons.automirrored.outlined.KeyboardTab
import androidx.compose.material.icons.filled.Keyboard
import androidx.compose.material.icons.outlined.Add
import androidx.compose.material.icons.outlined.AspectRatio
import androidx.compose.material.icons.outlined.BrightnessLow
import androidx.compose.material.icons.outlined.Cancel
import androidx.compose.material.icons.outlined.ContentPaste
import androidx.compose.material.icons.outlined.ExpandLess
import androidx.compose.material.icons.outlined.FilterNone
import androidx.compose.material.icons.outlined.Fullscreen
import androidx.compose.material.icons.outlined.HighlightOff
import androidx.compose.material.icons.outlined.History
import androidx.compose.material.icons.outlined.Key
import androidx.compose.material.icons.outlined.KeyboardArrowDown
import androidx.compose.material.icons.outlined.KeyboardArrowRight
import androidx.compose.material.icons.outlined.KeyboardArrowUp
import androidx.compose.material.icons.outlined.KeyboardHide
import androidx.compose.material.icons.outlined.LightMode
import androidx.compose.material.icons.outlined.Mail
import androidx.compose.material.icons.outlined.PanTool
import androidx.compose.material.icons.outlined.PhoneAndroid
import androidx.compose.material.icons.outlined.PrivacyTip
import androidx.compose.material.icons.outlined.Search
import androidx.compose.material.icons.outlined.Settings
import androidx.compose.material.icons.outlined.Speed
import androidx.compose.material.icons.outlined.Slideshow
import androidx.compose.material.icons.outlined.UnfoldMore
import androidx.compose.ui.graphics.vector.ImageVector

/** The glyphs of the session screen and its panels, named for the SF Symbol each one stands in for. */
object SessionIcons {
    val apps: ImageVector get() = Icons.Outlined.FilterNone
    val keyboard: ImageVector get() = AppIcons.keyboard
    val keyboardOn: ImageVector get() = Icons.Filled.Keyboard
    val hideKeyboard: ImageVector get() = Icons.Outlined.KeyboardHide
    val clipboard: ImageVector get() = Icons.Outlined.ContentPaste
    val tab: ImageVector get() = Icons.AutoMirrored.Outlined.KeyboardTab
    val enter: ImageVector get() = Icons.AutoMirrored.Outlined.KeyboardReturn
    val delete: ImageVector get() = Icons.AutoMirrored.Outlined.Backspace
    val escape: ImageVector get() = Icons.Outlined.HighlightOff
    val settings: ImageVector get() = Icons.Outlined.Settings
    val up: ImageVector get() = Icons.Outlined.KeyboardArrowUp
    val down: ImageVector get() = Icons.Outlined.KeyboardArrowDown
    val left: ImageVector get() = Icons.AutoMirrored.Outlined.KeyboardArrowLeft
    val right: ImageVector get() = Icons.Outlined.KeyboardArrowRight
    val collapse: ImageVector get() = Icons.Outlined.ExpandLess
    val immersive: ImageVector get() = Icons.Outlined.Fullscreen
    val fill: ImageVector get() = Icons.Outlined.AspectRatio
    val dim: ImageVector get() = Icons.Outlined.BrightnessLow
    val bright: ImageVector get() = Icons.Outlined.LightMode
    val search: ImageVector get() = Icons.Outlined.Search
    val clearSearch: ImageVector get() = Icons.Outlined.Cancel
    val unfold: ImageVector get() = Icons.Outlined.UnfoldMore
    val phone: ImageVector get() = Icons.Outlined.PhoneAndroid
    val history: ImageVector get() = Icons.Outlined.History
    val add: ImageVector get() = Icons.Outlined.Add
    val hand: ImageVector get() = Icons.Outlined.PanTool
    val speed: ImageVector get() = Icons.Outlined.Speed
    val key: ImageVector get() = Icons.Outlined.Key
    val mail: ImageVector get() = Icons.Outlined.Mail
    val privacy: ImageVector get() = Icons.Outlined.PrivacyTip
    val introduction: ImageVector get() = Icons.Outlined.Slideshow
}
