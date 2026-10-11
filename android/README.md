# Peering for Android

Kotlin, Jetpack Compose, Material 3. Plan: `docs/plans/android-and-windows.md`. Protocol: `docs/protocol.md`.

```
cd android
./gradlew :core:wire:test :core:session:test    # pure Kotlin logic, runs on a laptop
```

`core:wire` and `core:session` MUST stay free of Android classes so their tests run on the JVM.
