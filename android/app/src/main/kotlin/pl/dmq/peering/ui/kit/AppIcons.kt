package pl.dmq.peering.ui.kit

import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.automirrored.outlined.ArrowBack
import androidx.compose.material.icons.automirrored.outlined.ArrowForward
import androidx.compose.material.icons.automirrored.outlined.HelpOutline
import androidx.compose.material.icons.outlined.AllInclusive
import androidx.compose.material.icons.outlined.AutoAwesome
import androidx.compose.material.icons.outlined.Check
import androidx.compose.material.icons.outlined.CheckCircle
import androidx.compose.material.icons.outlined.Edit
import androidx.compose.material.icons.outlined.Fingerprint
import androidx.compose.material.icons.outlined.ChevronRight
import androidx.compose.material.icons.outlined.Close
import androidx.compose.material.icons.outlined.ContentCopy
import androidx.compose.material.icons.outlined.DesktopWindows
import androidx.compose.material.icons.outlined.Devices
import androidx.compose.material.icons.outlined.Download
import androidx.compose.material.icons.outlined.ExpandMore
import androidx.compose.material.icons.outlined.FitScreen
import androidx.compose.material.icons.outlined.GridView
import androidx.compose.material.icons.outlined.Keyboard
import androidx.compose.material.icons.outlined.KeyboardCommandKey
import androidx.compose.material.icons.outlined.Lan
import androidx.compose.material.icons.outlined.Language
import androidx.compose.material.icons.outlined.Folder
import androidx.compose.material.icons.automirrored.outlined.InsertDriveFile
import androidx.compose.material.icons.outlined.Laptop
import androidx.compose.material.icons.outlined.Layers
import androidx.compose.material.icons.outlined.Lock
import androidx.compose.material.icons.outlined.Menu
import androidx.compose.material.icons.outlined.Mouse
import androidx.compose.material.icons.outlined.MoreVert
import androidx.compose.material.icons.outlined.NearMe
import androidx.compose.material.icons.outlined.NotificationsActive
import androidx.compose.material.icons.outlined.OpenInNew
import androidx.compose.material.icons.outlined.PersonOff
import androidx.compose.material.icons.outlined.PhonelinkLock
import androidx.compose.material.icons.outlined.PhotoCamera
import androidx.compose.material.icons.outlined.PictureInPictureAlt
import androidx.compose.material.icons.outlined.PowerSettingsNew
import androidx.compose.material.icons.outlined.QrCodeScanner
import androidx.compose.material.icons.outlined.Refresh
import androidx.compose.material.icons.outlined.Sensors
import androidx.compose.material.icons.outlined.Shield
import androidx.compose.material.icons.outlined.Sync
import androidx.compose.material.icons.outlined.Tag
import androidx.compose.material.icons.outlined.Tune
import androidx.compose.material.icons.outlined.TouchApp
import androidx.compose.material.icons.outlined.Delete
import androidx.compose.material.icons.outlined.VerifiedUser
import androidx.compose.material.icons.outlined.Visibility
import androidx.compose.material.icons.outlined.Warning
import androidx.compose.material.icons.outlined.Wifi
import androidx.compose.material.icons.outlined.WifiOff
import androidx.compose.material.icons.outlined.Window
import androidx.compose.material.icons.outlined.Code
import androidx.compose.material.icons.outlined.Description
import androidx.compose.material.icons.outlined.FolderZip
import androidx.compose.material.icons.outlined.Image
import androidx.compose.material.icons.outlined.SignalCellularAlt
import androidx.compose.material.icons.outlined.SignalCellularAlt1Bar
import androidx.compose.material.icons.outlined.SignalCellularAlt2Bar
import androidx.compose.ui.graphics.vector.ImageVector

/** The Material Symbols the screens share, named for the idea they carry rather than for the glyph. */
object AppIcons {
    val computer: ImageVector get() = Icons.Outlined.Laptop
    val devices: ImageVector get() = Icons.Outlined.Devices
    val wifi: ImageVector get() = Icons.Outlined.Wifi
    val wifiOff: ImageVector get() = Icons.Outlined.WifiOff
    val number: ImageVector get() = Icons.Outlined.Tag
    val shield: ImageVector get() = Icons.Outlined.Shield
    val verifiedShield: ImageVector get() = Icons.Outlined.VerifiedUser
    val encrypted: ImageVector get() = Icons.Outlined.Lock
    val globe: ImageVector get() = Icons.Outlined.Language
    val network: ImageVector get() = Icons.Outlined.Lan
    val nearby: ImageVector get() = Icons.Outlined.Sensors
    val refresh: ImageVector get() = Icons.Outlined.Refresh
    val more: ImageVector get() = Icons.Outlined.MoreVert
    val expand: ImageVector get() = Icons.Outlined.ExpandMore
    val back: ImageVector get() = Icons.AutoMirrored.Outlined.ArrowBack
    val close: ImageVector get() = Icons.Outlined.Close
    val chevronRight: ImageVector get() = Icons.Outlined.ChevronRight
    val openExternal: ImageVector get() = Icons.Outlined.OpenInNew
    val arrowForward: ImageVector get() = Icons.AutoMirrored.Outlined.ArrowForward
    val copy: ImageVector get() = Icons.Outlined.ContentCopy
    val check: ImageVector get() = Icons.Outlined.Check
    val checkCircle: ImageVector get() = Icons.Outlined.CheckCircle
    val download: ImageVector get() = Icons.Outlined.Download
    val warning: ImageVector get() = Icons.Outlined.Warning
    val qrScanner: ImageVector get() = Icons.Outlined.QrCodeScanner
    val keyboard: ImageVector get() = Icons.Outlined.Keyboard
    val noAccount: ImageVector get() = Icons.Outlined.PersonOff
    val reconnect: ImageVector get() = Icons.Outlined.Sync
    val display: ImageVector get() = Icons.Outlined.DesktopWindows
    val window: ImageVector get() = Icons.Outlined.Window
    val spaces: ImageVector get() = Icons.Outlined.Layers
    val pointer: ImageVector get() = Icons.Outlined.NearMe
    val command: ImageVector get() = Icons.Outlined.KeyboardCommandKey
    val observe: ImageVector get() = Icons.Outlined.Visibility
    val pictureInPicture: ImageVector get() = Icons.Outlined.PictureInPictureAlt
    val lockedPhone: ImageVector get() = Icons.Outlined.PhonelinkLock
    val grid: ImageVector get() = Icons.Outlined.GridView
    val tap: ImageVector get() = Icons.Outlined.TouchApp
    val notification: ImageVector get() = Icons.Outlined.NotificationsActive
    val unlimited: ImageVector get() = Icons.Outlined.AllInclusive
    val sparkles: ImageVector get() = Icons.Outlined.AutoAwesome
    val help: ImageVector get() = Icons.AutoMirrored.Outlined.HelpOutline
    val delete: ImageVector get() = Icons.Outlined.Delete
    val edit: ImageVector get() = Icons.Outlined.Edit
    val fingerprint: ImageVector get() = Icons.Outlined.Fingerprint
    val camera: ImageVector get() = Icons.Outlined.PhotoCamera
    val fit: ImageVector get() = Icons.Outlined.FitScreen
    val menu: ImageVector get() = Icons.Outlined.Menu
    val trackpad: ImageVector get() = Icons.Outlined.Mouse
    val file: ImageVector get() = Icons.AutoMirrored.Outlined.InsertDriveFile
    val folder: ImageVector get() = Icons.Outlined.Folder
    val power: ImageVector get() = Icons.Outlined.PowerSettingsNew
    val tune: ImageVector get() = Icons.Outlined.Tune
    val signalLow: ImageVector get() = Icons.Outlined.SignalCellularAlt1Bar
    val signalMedium: ImageVector get() = Icons.Outlined.SignalCellularAlt2Bar
    val signalHigh: ImageVector get() = Icons.Outlined.SignalCellularAlt
    val image: ImageVector get() = Icons.Outlined.Image
    val code: ImageVector get() = Icons.Outlined.Code
    val archive: ImageVector get() = Icons.Outlined.FolderZip
    val document: ImageVector get() = Icons.Outlined.Description
}
