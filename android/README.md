# Peering for Android

Kotlin, Jetpack Compose, Material 3. Plan: `docs/plans/android-and-windows.md`. Protocol: `docs/protocol.md`.

## Tests

```
cd android
./gradlew :core:wire:test :core:session:test            # pure Kotlin logic, runs on a laptop
./gradlew :core:platform:testDebugUnitTest :app:testDebugUnitTest
```

`core:wire` and `core:session` MUST stay free of Android classes so their tests run on the JVM.

## Run it on a phone

Needs the Android SDK (platform 35) and JDK 17. `android/local.properties` holds `sdk.dir` and is not tracked.

1. On the phone: Settings, About phone, tap Build number seven times; then Developer options, turn on USB debugging (or Wireless debugging).
2. Connect it by USB and accept the debugging prompt. Check that it shows up:
   `~/Library/Android/sdk/platform-tools/adb devices` (the state must say `device`, not `unauthorized`).
3. Install and start the debug build:
   ```
   cd android
   ./gradlew :app:installDebug
   ~/Library/Android/sdk/platform-tools/adb shell am start -n pl.dmq.peering/.MainActivity
   ```
4. Read the log while you test: `adb logcat --pid=$(adb shell pidof pl.dmq.peering)`.
5. Wireless instead of USB (Android 11 and later): Developer options, Wireless debugging, Pair device with pairing code, then
   `adb pair <ip>:<pairing port>` and `adb connect <ip>:<port>`.

The phone and the Mac must be on the same Wi-Fi network for the local discovery path. Allow the local network and camera
permissions when asked. For the relay path no network setup is needed.

## Sessions and the background

While a session is open (connecting, ready or reconnecting) a foreground service of type `specialUse`
(`background/SessionKeepAliveService.kt`) holds the process, behind a low-priority ongoing notification that names the
computer, returns to the session when tapped and has a Disconnect button. The service starts while the app is on screen
(Android refuses to start one from the background) and stops when the session ends. The Settings row "Keep sessions in
the background" turns it off.

* The phone tells the host it is in the background (`clientState`, only to a host that declared `supportsClientState`),
  so the Mac pauses the picture, and the host may stay silent for 30 s instead of 3 s before the link counts as lost.
* With the service off, or when Android refuses to start it, Android may stop the connection of a backgrounded app (Doze,
  app standby, battery limits). A session lost while the app was away is started once more when the app returns, and a
  second failure is shown to the user.
* While away, local notifications (channels Approval requests, Terminal prompts, Agent finished) say that an agent needs
  approval (with Allow and Deny, or the answers of a one-question ask, as buttons), that a terminal waits for a password
  or confirmation, or that an agent finished. They are retracted when the app returns or the ask is answered elsewhere.
  The planner is `core/session/.../notices/BackgroundNotices.kt`; `background/` is the thin Android side.
* POST_NOTIFICATIONS (Android 13+) is asked for after a one-time explanation when the first session starts, and again from
  the Settings "Notifications" toggle (which opens the system settings after a refusal). Without it the service still
  runs and no notices are shown.

Play Console needs a foreground service declaration for `specialUse`; the manifest property carries the justification.
Push while the app is fully closed (FCM through the relay) is not built, see `docs/TODO.md`.

## First run against a Mac host

See `docs/plans/interop-android-mac.md` for the on-device checklist (pairing, video, input).

## Optional configuration

* Firebase push (not required): put your `google-services.json` in `android/app/` (it is gitignored); `google-services.example.json`
  shows the shape and holds no real keys. Without the file the app runs with push disabled.
* Google Play Billing needs products set up in Play Console; without them the paywall explains that billing is unavailable.
