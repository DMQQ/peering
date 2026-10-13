# Android Connect parity checklist

Source: `apple/Peering/Connection/HostPickerView+HomeTab.swift`, `+HomeHeader`, `+HomeCards`, `+HomeRows`, `ManualConnectionSheet`, `RemotePairingSheet`, and `marketing/appstore/raw/en/01-connect.png`.

Screen column: 18 pt side inset, 20 pt between blocks, 36 pt at the bottom.

| # | iPhone element | Android implementation |
|---|----------------|------------------------|
| 1 | Pears mark, left aligned, 72 pt | `ConnectHeader`, `R.drawable.pears` |
| 2 | Wordmark "Peering", serif 60 pt, sheen | `ConnectHeader`, `wordmarkStyle` with `rememberSheen` |
| 3 | Tagline "Your Mac, from anywhere." (computer) | `ConnectHeader`, `connect_tagline` |
| 4 | Failure card: warning tile, message, dismiss cross | `FailureCard`, `ConnectPresenter.dismissMessage` |
| 5 | Resume card | Not built: no resumable activity exists on Android |
| 6 | First connection card (no trusted Mac): wifi tile, title, body, outlined "Get Peering for Mac" button | `FirstConnectionCard`, outlined `QuietButton` opening the download page |
| 7 | One outlined card with three sections split by hairlines | `ConnectScreen`: one `cardBackground` column, 16 dp section padding, `HorizontalDivider` |
| 7a | Nearby: label, spinner while no hosts, spacer, "Connect by address" pill, round refresh button | `NearbySection`, `CapsuleChip`, `CircleIconButton` |
| 7b | Nearby rows: laptop tile with presence dot, name, 8 character id in monospace, no chevron, tap pairs | `HostRowCard` with `onPair` |
| 7c | Local network notice when the system refuses | `NoWifiNotice` when the phone is not on Wi-Fi, ink "Open Wi-Fi settings" button |
| 7d | Status line under the rows: "N Macs found", or tertiary "Looking for Macs on this network" | `nearbyStatus`: plural, "No computers found on this network.", or searching |
| 7e | Another network: globe label, row with number tile, "Pair with a Mac elsewhere", "Type or scan the device ID shown on it." | `RemotePairingEntry` opening `HostIdEntrySheet` |
| 7f | Trusted Macs: shield label, empty row with shield tile and sentence, or rows | `PairedSection` |
| 7g | Trusted row: tile with filled or hollow dot, name, monospace detail, ellipsis menu (not a chevron) | `HostRowCard` with `HostMenu` |
| 7h | Menu: Connect via LAN (only when nearby), Connect via Relay, Wake Mac on LAN, Rename, Forget | `HostMenu` and `ConnectVia`; Wake on LAN is not built |
| 7i | Forget alert and Rename alert with a name field | `ForgetDialog`, `RenameDialog`, `HostAliases` keeps names on the device |
| 8 | Protect paired Macs card: faceid tile, title, caption, switch | `ProtectionCard` with `AppLock` and the system `BiometricPrompt`; `MainActivity` locks on return |
| 9 | Connect by Address sheet: title, address and port fields, Connect | `ManualAddressSheet` (unchanged) |
| 10 | Pair from Another Network sheet: title, Device ID card with field, paste row, scan row, footer, error line, Pair | `HostIdEntrySheet` (unchanged) |
| 11 | Root tab bar | Material 3 `NavigationBar` (unchanged) |
