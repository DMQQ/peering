# On-device checklist: Android client against the Mac host (AND-090)

Status: not run yet. Fill in the Result column on the day and note the app and host build numbers.

Before you start: Mac host (Peering Host, built from the current tree or the shipped build) is running and shows its device ID and
QR code; the phone is on the same Wi-Fi network; `./gradlew :app:installDebug` was run (see `android/README.md`); screen recording
permission is granted to the host on the Mac. Open `adb logcat` filtered to the app in a terminal.

| # | Step | Expected | Result |
|---|---|---|---|
| 1 | Open the app for the first time | First run screen, then the Connect tab. The Mac appears under nearby hosts within a few seconds | |
| 2 | Tap the Mac | Pairing starts; six digits appear on the phone and in the Mac host window | |
| 3 | Compare the digits and confirm on the phone | Pairing completes; the Mac lists the phone as trusted; the phone shows the Mac screen | |
| 4 | Look at the picture | The Mac desktop is visible, sharp, no green frames, updates when you move a window | |
| 5 | Move your finger on the phone (trackpad mode) | The Mac cursor moves; tap clicks; two finger drag scrolls | |
| 6 | Type with the soft keyboard in a Mac text field | Text appears; Backspace and Return work; Shift, Ctrl and Cmd from the modifier bar combine with a key | |
| 7 | Open Sources and pick another display (if the Mac has one) | Picture switches, input follows the new display | |
| 8 | Force close the app and reopen, tap the Mac | Reconnects without pairing again; the picture returns | |
| 9 | Turn Wi-Fi off on the phone for 10 seconds, then on | The session reconnects by itself (or shows Reconnecting then Ready) | |
| 10 | Stop hosting on the Mac | The phone shows that the host stopped and does not keep retrying | |
| 11 | If the Mac host build streams HEVC and the picture is blank | Note it; in the Mac host settings set the codec to H.264 and retry, then report (the phone sends its decoder list in the hello) | |
| 12 | Settings, forget the Mac; pair again | Pairing works again from scratch | |

What to capture when something fails: the `adb logcat` output around the failure, the Mac host log
(`/usr/bin/log show --last 5m --style compact --predicate 'subsystem == "pl.dmq.peering.host"'`), the phone model and Android version,
and which step failed.
