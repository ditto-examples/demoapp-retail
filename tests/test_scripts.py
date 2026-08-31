"""Hermetic tests for scripts/vendor_anvil.sh and scripts/sync_benchmarks.sh.

Each script computes REPO_ROOT from its own location, so tests copy the script
into a tmp dir (making the tmp dir the "repo root") and run it against fixture
trees — the real vendor/ and shared/ are never touched.
"""
import json
import os
import shutil
import stat
import subprocess
import tempfile
import unittest
from pathlib import Path

import _support as S

VENDOR_SH = S.REPO_ROOT / "scripts" / "vendor_anvil.sh"
SYNC_SH = S.REPO_ROOT / "scripts" / "sync_benchmarks.sh"


def run(script: Path, *args: str, cwd: Path) -> subprocess.CompletedProcess:
    return subprocess.run(["bash", str(script), *args], cwd=cwd,
                          capture_output=True, text=True, timeout=120)


def make_fake_anvil(root: Path, catalog_agp_line: str = 'agp = "8.13.2"') -> Path:
    anvil = root / "anvil"
    # Swift package (+ junk that must be excluded)
    (anvil / "swift/Anvil/Sources/Anvil").mkdir(parents=True)
    (anvil / "swift/Anvil/Package.swift").write_text("// package")
    (anvil / "swift/Anvil/Sources/Anvil/X.swift").write_text("// x")
    (anvil / "swift/Anvil/.build/junk").mkdir(parents=True)
    (anvil / "swift/Anvil/.swiftpm/junk").mkdir(parents=True)

    # Android tree
    (anvil / "android/gradle").mkdir(parents=True)
    (anvil / "android/build.gradle.kts").write_text("// root build")
    (anvil / "android/gradle.properties").write_text("android.useAndroidX=true\n")
    (anvil / "android/settings.gradle.kts").write_text(
        'rootProject.name = "anvil-android"\n'
        'pluginManagement {\n    repositories {\n        google()\n    }\n}\n'
        'dependencyResolutionManagement {\n    repositories {\n        google()\n    }\n}\n'
        'include(":anvil-tokens")\ninclude(":anvil-cmp")\ninclude(":anvil-material3")\n'
        'include(":catalog")\ninclude(":catalog-expressive")\n')
    (anvil / "android/gradle/libs.versions.toml").write_text(
        f'[versions]\n{catalog_agp_line}\nkotlin = "2.2.21"\n'
        'composeMultiplatform = "1.9.3"\n')
    for mod in ("anvil-tokens", "anvil-material3"):
        d = anvil / "android" / mod
        d.mkdir(parents=True)
        (d / "build.gradle.kts").write_text("// module")
        (d / "build").mkdir()            # junk
        (d / ".idea").mkdir()            # junk
        (d / "local.properties").write_text("sdk.dir=/somewhere")  # junk
    for dropped in ("anvil-cmp", "catalog", "catalog-expressive"):
        (anvil / "android" / dropped).mkdir(parents=True)  # must NOT be copied

    # Flutter package with fonts (+ junk)
    fonts = anvil / "flutter/anvil/fonts"
    fonts.mkdir(parents=True)
    for f in ("inter_regular", "inter_medium", "inter_semibold", "inter_bold",
              "ibm_plex_mono_regular", "ibm_plex_mono_bold", "ibm_plex_mono_italic"):
        (fonts / f"{f}.ttf").write_bytes(b"ttf")
    (anvil / "flutter/anvil/pubspec.yaml").write_text("name: anvil")
    (anvil / "flutter/anvil/pubspec.lock").write_text("lock")   # junk
    (anvil / "flutter/anvil/build").mkdir(parents=True)          # junk

    # RN package (+ junk)
    (anvil / "react-native/anvil/src").mkdir(parents=True)
    (anvil / "react-native/anvil/package.json").write_text("{}")
    (anvil / "react-native/anvil/node_modules").mkdir(parents=True)  # junk
    return anvil


class VendorAnvilScript(unittest.TestCase):
    def setUp(self):
        self._tmp = tempfile.TemporaryDirectory()
        self.root = Path(self._tmp.name)
        (self.root / "scripts").mkdir()
        self.script = self.root / "scripts" / "vendor_anvil.sh"
        shutil.copy(VENDOR_SH, self.script)
        self.script.chmod(self.script.stat().st_mode | stat.S_IXUSR)

    def tearDown(self):
        self._tmp.cleanup()

    def test_happy_path_copies_modules_and_applies_overrides(self):
        anvil = make_fake_anvil(self.root)
        res = run(self.script, str(anvil), cwd=self.root)
        self.assertEqual(res.returncode, 0, res.stderr)
        dest = self.root / "vendor/anvil"

        # settings trimmed to exactly the two copied modules
        settings = (dest / "android/settings.gradle.kts").read_text()
        self.assertIn('include(":anvil-tokens")', settings)
        self.assertIn('include(":anvil-material3")', settings)
        for dropped in ("anvil-cmp", "catalog"):
            self.assertNotIn(dropped, settings)
            self.assertFalse((dest / "android" / dropped).exists())
        self.assertIn("pluginManagement", settings)  # kept verbatim

        # toolchain overrides landed
        catalog = (dest / "android/gradle/libs.versions.toml").read_text()
        self.assertIn('agp = "9.3.1"', catalog)
        self.assertIn('kotlin = "2.4.10"', catalog)
        props = (dest / "android/gradle.properties").read_text()
        self.assertIn("android.builtInKotlin=false", props)

        # junk excluded
        for junk in ("android/anvil-tokens/local.properties",
                     "android/anvil-tokens/.idea",
                     "android/anvil-tokens/build",
                     "flutter/anvil/pubspec.lock",
                     "flutter/anvil/build",
                     "react-native/anvil/node_modules",
                     "swift/Anvil/.build",
                     "swift/Anvil/.swiftpm"):
            self.assertFalse((dest / junk).exists(), junk)

        # packages present
        self.assertTrue((dest / "swift/Anvil/Package.swift").exists())
        self.assertTrue((dest / "flutter/anvil/pubspec.yaml").exists())
        self.assertTrue((dest / "react-native/anvil/package.json").exists())

        # fonts: exactly one Inter (the variable font) + three Plex Mono
        fonts = sorted(p.name for p in (dest / "fonts").iterdir())
        self.assertEqual(fonts, ["ibm_plex_mono_bold.ttf", "ibm_plex_mono_italic.ttf",
                                 "ibm_plex_mono_regular.ttf", "inter_regular.ttf"])

        # provenance recorded (fixture is not a git repo)
        commit = (dest / "COMMIT").read_text()
        self.assertIn("commit: unknown", commit)
        self.assertIn("branch: detached-or-unknown", commit)

    def test_fails_loudly_when_override_anchor_drifts(self):
        # Upstream renames/re-indents the agp line -> sed no-ops -> must fail.
        anvil = make_fake_anvil(self.root, catalog_agp_line='# agp was removed')
        res = run(self.script, str(anvil), cwd=self.root)
        self.assertNotEqual(res.returncode, 0)
        self.assertIn("agp override did not apply", res.stderr)


class SyncBenchmarksScript(unittest.TestCase):
    def setUp(self):
        self._tmp = tempfile.TemporaryDirectory()
        self.root = Path(self._tmp.name)
        (self.root / "scripts").mkdir()
        self.script = self.root / "scripts" / "sync_benchmarks.sh"
        shutil.copy(SYNC_SH, self.script)
        self.script.chmod(self.script.stat().st_mode | stat.S_IXUSR)
        self.bench_repo = self.root / "bench-repo"
        (self.bench_repo / "benchmarks/retail").mkdir(parents=True)

    def tearDown(self):
        self._tmp.cleanup()

    def test_syncs_catalog_and_provenance(self):
        catalog = {"a__select__x": {"query": "SELECT 1", "category": "SELECT"},
                   "b__select__y": {"query": "SELECT 2", "category": "SELECT"}}
        (self.bench_repo / "benchmarks/retail/benchmarks.json").write_text(json.dumps(catalog))
        res = run(self.script, str(self.bench_repo), cwd=self.root)
        self.assertEqual(res.returncode, 0, res.stderr)
        out = self.root / "shared/benchmarks.json"
        self.assertEqual(json.loads(out.read_text()), catalog)
        self.assertIn("2 benchmarks synced", res.stdout)
        self.assertTrue((self.root / "shared/COMMIT").exists())

    def test_rejects_empty_catalog(self):
        (self.bench_repo / "benchmarks/retail/benchmarks.json").write_text("{}")
        res = run(self.script, str(self.bench_repo), cwd=self.root)
        self.assertNotEqual(res.returncode, 0)

    def test_missing_catalog(self):
        res = run(self.script, str(self.bench_repo), cwd=self.root)
        self.assertNotEqual(res.returncode, 0)


if __name__ == "__main__":
    unittest.main()
