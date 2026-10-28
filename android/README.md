# Ditto Retail — Android (Jetpack Compose)

The Android port of the Ditto Retail demo app (see [../README.md](../README.md)
for what the app demos and where the data comes from, and
[../PLAN.md](../PLAN.md) for the full design). Kotlin 2.4, Jetpack Compose
(Material 3 + Navigation 3), AGP 9, minSdk in line with the Ditto SDK.

## Stack

- **Ditto**: `ditto-kotlin` 5.2.0 + `ditto-tools-android` 6.0.0 (Ditto tab)
- **Design system**: [Anvil](../vendor/anvil/android) (vendored Compose theme
  and components)
- **Architecture**: `DittoManager` singleton object (the only Ditto access
  point) + an app-level `AppState`; screens hold their own observer state.
  DQL strings live at the call site — these apps teach the SDK.
- **Env**: the Gradle build reads the repository-root `.env` and bakes
  `DITTO_DATABASE_ID` / `DITTO_DEVELOPMENT_TOKEN` / `DITTO_SERVER_URL` into
  `BuildConfig` — rebuild after editing `.env`.

## Setup & run

Prereqs: a current JDK + Android SDK (Android Studio Ladybug-era or newer
works), and the repository-root `.env` — see [../README.md](../README.md)
→ Quickstart for how to create a Ditto account + database, the five values
to copy from the Portal's **Connect** tab, and where to find them. Seed Big
Peer first if you want data on launch: `python3 ../scripts/load_data.py`.

```sh
./gradlew :app:assembleDebug   # build
./gradlew :app:installDebug    # install on the connected device/emulator
```

Or open `android/` in Android Studio and run the `app` configuration.

> **Local Big Peer over LAN**: if `DITTO_SERVER_URL` points at a plain-HTTP
> address (e.g. a self-managed Big Peer on your network), that host must be
> listed in `app/src/main/res/xml/network_security_config.xml` — Android
> blocks cleartext by default, and the file documents exactly what to add.

## Tests

```sh
./gradlew :app:testDebugUnitTest   # pure-logic unit tests
```

## Notes

- `app/src/main/java/live/ditto/zava/ui/orders/OrdersScreen.kt` is the
  best first read: a live JOIN observer with LIMIT/OFFSET pagination and a
  parallel live `COUNT(*)` — the pattern every other screen reuses.
- Agent-focused conventions and platform gotchas live in
  [AGENTS.md](AGENTS.md).
