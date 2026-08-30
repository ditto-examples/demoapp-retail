#!/usr/bin/env python3
"""Coverage gate: fails if the ZavaRetail target's line coverage is below the
given threshold (default 85%).

  python3 scripts/check_coverage.py build/TestResults.xcresult [threshold]

Reads `xcrun xccov view --report --json` and prints a per-file breakdown so a
failure points at exactly where the missing coverage lives.
"""
import json
import subprocess
import sys


def main() -> int:
    bundle = sys.argv[1] if len(sys.argv) > 1 else "build/TestResults.xcresult"
    threshold = float(sys.argv[2]) if len(sys.argv) > 2 else 85.0

    out = subprocess.run(
        ["xcrun", "xccov", "view", "--report", "--json", bundle],
        capture_output=True, text=True, check=True,
    ).stdout
    report = json.loads(out)

    target = next(
        (t for t in report["targets"] if t["name"].startswith("ZavaRetail.app")),
        None,
    )
    if target is None:
        print("error: ZavaRetail.app target not found in coverage report", file=sys.stderr)
        return 2

    total = target["lineCoverage"] * 100
    covered = target["coveredLines"]
    executable = target["executableLines"]
    print(f"ZavaRetail: {total:.1f}% line coverage ({covered}/{executable} lines), gate {threshold:.0f}%")

    worst = sorted(
        ((f["lineCoverage"], f["name"]) for f in target["files"]),
        key=lambda x: x[0],
    )[:12]
    print("\nLowest-coverage files:")
    for cov, name in worst:
        print(f"  {cov * 100:5.1f}%  {name}")

    if total < threshold:
        print(f"\nFAIL: {total:.1f}% < {threshold:.0f}%", file=sys.stderr)
        return 1
    print("\nPASS")
    return 0


if __name__ == "__main__":
    sys.exit(main())
