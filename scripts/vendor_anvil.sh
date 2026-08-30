#!/usr/bin/env bash
# Vendor the Anvil design system (unpublished) into vendor/anvil/ from a local
# checkout, per PLAN.md §5. Re-run any time; the pinned upstream commit is
# recorded in vendor/anvil/COMMIT. Never hand-edit vendored files.
#
#   scripts/vendor_anvil.sh [ANVIL_CHECKOUT_DIR]     (default: ../../anvil)
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
ANVIL_DIR="${1:-${ANVIL_DIR:-$REPO_ROOT/../anvil}}"
DEST="$REPO_ROOT/vendor/anvil"

if [[ ! -d "$ANVIL_DIR/swift/Anvil" ]]; then
  echo "error: Anvil checkout not found at $ANVIL_DIR" >&2
  exit 1
fi

echo "Vendoring Anvil from $ANVIL_DIR"
rm -rf "$DEST"
mkdir -p "$DEST/swift" "$DEST/android/gradle" "$DEST/flutter" "$DEST/react-native" "$DEST/fonts"

# --- Swift: SPM package as-is -------------------------------------------------
rsync -a --exclude '.build' "$ANVIL_DIR/swift/Anvil" "$DEST/swift/"

# --- Android: anvil-tokens + anvil-material3 + root build scaffolding ---------
# The root build.gradle.kts (group/version -> includeBuild substitution),
# gradle.properties (android.useAndroidX, compileSdk suppression) and the
# version catalog are all required for the modules to configure (PLAN §5, B1).
rsync -a --exclude 'build' --exclude 'local.properties' --exclude '.idea' --exclude '.gradle' \
  "$ANVIL_DIR/android/anvil-tokens" "$ANVIL_DIR/android/anvil-material3" "$DEST/android/"
cp "$ANVIL_DIR/android/build.gradle.kts" "$ANVIL_DIR/android/gradle.properties" "$DEST/android/"
cp "$ANVIL_DIR/android/gradle/libs.versions.toml" "$DEST/android/gradle/"
# Trimmed settings: keep pluginManagement/dependencyResolutionManagement
# verbatim, drop :anvil-cmp (never mix with :anvil-material3) and the catalogs.
grep -vE 'include\(":(anvil-cmp|catalog|catalog-expressive)"\)' \
  "$ANVIL_DIR/android/settings.gradle.kts" > "$DEST/android/settings.gradle.kts"

# Vendored toolchain overrides (owned by this script — never hand-edit the
# vendored copy). M0 spike 1 finding: AGP 8.x cannot run on Gradle 9.6+
# (org.gradle.api.problems.internal.InternalProblems was removed), and a
# composite build runs ONE Gradle runtime — the consumer app's (9.7). So the
# vendored Android modules are re-pinned to the app's toolchain:
#   AGP 8.13.2 -> 9.3.1, Kotlin 2.2.21 -> 2.4.10
# and opt out of AGP 9's built-in Kotlin (the modules apply their own KGP,
# same as the app does). The Compose Multiplatform *library* coordinate stays
# at 1.9.3 (Kotlin 2.4 reads older klibs fine).
sed -i '' -E \
  -e 's/^agp = "[^"]+"/agp = "9.3.1"      # vendored override (was 8.13.2): AGP 8.x cannot run on the consumers Gradle 9.7/' \
  -e 's/^kotlin = "[^"]+"/kotlin = "2.4.10"   # vendored override (was 2.2.21): align with the consuming app/' \
  "$DEST/android/gradle/libs.versions.toml"
cat >> "$DEST/android/gradle.properties" <<'EOF'

# Vendored override (vendor_anvil.sh): run on the consumer app's modern
# AGP 9 / Kotlin 2.4 toolchain — opt out of AGP 9's built-in Kotlin and the
# new DSL (these modules apply their own Kotlin Gradle Plugin).
android.builtInKotlin=false
android.newDsl=false
EOF

# --- Flutter: pub package as-is (fonts bundled inside) ------------------------
rsync -a --exclude 'build' --exclude '.dart_tool' --exclude 'pubspec.lock' \
  "$ANVIL_DIR/flutter/anvil" "$DEST/flutter/"

# --- React Native: npm package as-is (ships raw TS source, no build) ----------
rsync -a --exclude 'node_modules' "$ANVIL_DIR/react-native/anvil" "$DEST/react-native/"

# --- Fonts for Swift/RN (those ports do not bundle fonts) ----------------------
# The four inter_*.ttf upstream are byte-identical copies of one variable font
# (PostScript name "Inter"); ship one. IBM Plex Mono has three real faces.
cp "$ANVIL_DIR/flutter/anvil/fonts/inter_regular.ttf" "$DEST/fonts/"
cp "$ANVIL_DIR/flutter/anvil/fonts/ibm_plex_mono_regular.ttf" \
   "$ANVIL_DIR/flutter/anvil/fonts/ibm_plex_mono_bold.ttf" \
   "$ANVIL_DIR/flutter/anvil/fonts/ibm_plex_mono_italic.ttf" "$DEST/fonts/"

# --- Provenance ----------------------------------------------------------------
{
  echo "source: $ANVIL_DIR"
  echo "commit: $(git -C "$ANVIL_DIR" rev-parse HEAD 2>/dev/null || echo 'unknown')"
  echo "branch: $(git -C "$ANVIL_DIR" branch --show-current 2>/dev/null || echo 'unknown')"
  echo "vendored_at: $(date -u +%Y-%m-%dT%H:%M:%SZ)"
} > "$DEST/COMMIT"

echo "Vendored to $DEST"
cat "$DEST/COMMIT"
