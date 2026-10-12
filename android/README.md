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

## First run against a Mac host

See `docs/plans/interop-android-mac.md` for the on-device checklist (pairing, video, input).

## Optional configuration

* Firebase push (not required): put your `google-services.json` in `android/app/` (it is gitignored); `google-services.example.json`
  shows the shape and holds no real keys. Without the file the app runs with push disabled.
* Google Play Billing needs products set up in Play Console; without them the paywall explains that billing is unavailable.
