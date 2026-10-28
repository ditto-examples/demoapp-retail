# Ditto Retail — Flutter

The Flutter port of the Ditto Retail demo app (see [../README.md](../README.md)
for what the app demos and where the data comes from, and
[../PLAN.md](../PLAN.md) for the full design). UI-matched to the SwiftUI
reference and the Android app; Riverpod 3 for app-level state.

## Stack

- **Ditto**: `ditto_live` ^5.2.0 + `ditto_flutter_tools` ^3.0.0 (Ditto tab)
- **Design system**: [Anvil](../vendor/anvil/flutter) (vendored Flutter theme
  and components)
- **Architecture**: `DittoManager` singleton (the only Ditto access point)
  behind Riverpod providers; screens hold their own observer state in
  StatefulWidgets. DQL strings live at the call site — these apps teach the
  SDK.
- **Env**: the repository-root `.env` is injected at build/run time with
  `--dart-define-from-file=../.env` (`String.fromEnvironment` reads) —
  pass it on every `run`/`build`.

## Setup & run

Prereqs: **fvm** (this repo pins Flutter **3.47.0** via `.fvmrc` — run
everything through `fvm flutter …`), platform toolchains for your target
(Android SDK / Xcode), and the repository-root `.env` — see
[../README.md](../README.md) → Quickstart for how to create a Ditto account
+ database, the five values to copy from the Portal's **Connect** tab, and
where to find them. Seed Big Peer first if you want data on launch:
`python3 ../scripts/load_data.py`.

```sh
fvm flutter pub get
fvm flutter run -d <device> --dart-define-from-file=../.env

# one-off builds:
fvm flutter build apk --debug --dart-define-from-file=../.env
fvm flutter build ios --simulator --debug --dart-define-from-file=../.env
```

## Tests & analysis

```sh
fvm flutter analyze   # must be clean
fvm flutter test      # pure-logic unit tests
```

## Platform gotchas (already worked around — don't regress)

- **Android compileSdk**: Ditto's `transports-android` 5.2.x requires
  compileSdk 36+, but `ditto_flutter_tools` pins 35. `android/build.gradle.kts`
  forces every library subproject to `compileSdk = 36` in an `afterEvaluate`
  block that MUST run before `evaluationDependsOn(":app")`.
- **iOS simulator x86_64**: DittoCore.xcframework is arm64-only for the
  simulator. `Flutter/Debug.xcconfig` and `Flutter/Release.xcconfig`
  re-apply the `i386 x86_64` exclusion AFTER the tool-generated include;
  without it, `flutter build ios --simulator` fails with
  `framework 'DittoCore' not found`.

Agent-focused conventions live in [AGENTS.md](AGENTS.md).
