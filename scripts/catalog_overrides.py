#!/usr/bin/env python3
"""Apply shared/catalog_overrides.json to a benchmark catalog copy, and
recompute expected_count for patched entries against the committed data
bundle (shared/data/).

Why this exists: the retail-joins suite's literal queries reference ids from
the benchmark's own generated dataset ('order_20221209_0001', customer UUIDs,
'HND-0042'). Our apps load Microsoft's SHIPPED dataset, whose real ids are
different. The overrides (a) substitute real Microsoft row ids so the Query
Runner's literal lookups return real rows, (b) recompute the suite-stamped
expected_count against our bundle for patched entries, and (c) drop
expected_first_rows_hash on patched entries (a stale hash that can no longer
match is worse than none).

Everything else stays byte-identical to the upstream suite.

Usage:
  python3 scripts/catalog_overrides.py CATALOG_JSON OVERRIDES_JSON [DATA_DIR]

CATALOG_JSON is modified in place. If DATA_DIR is omitted (or lacks the
bundle), counts are not recomputed: patched entries lose expected_count too,
and a warning prints.
"""

from __future__ import annotations

import gzip
import json
import sys
from pathlib import Path

# Entry-name keyed recount rules for the queries the overrides can touch.
# (Kept explicit — full DQL evaluation is the store's job, not a text tool's.)
_BY_ID_ONE = [
    "orders__select__by_id",
    "orders__join__store_info",
    "orders__join__store_info_projection",
    "customers__select__by_id",
]
_ITEMS_FOR_ANCHOR_ORDER = ["items__join__orders", "items__join__products"]
_ORDERS_FOR_ANCHOR_CUSTOMER = ["customer__join__orders", "customer__join__orders_unfiltered"]
_BY_SKU_ONE = ["products__select__by_sku_indexed"]
_RECOMPUTED = set(_BY_ID_ONE + _ITEMS_FOR_ANCHOR_ORDER
                  + _ORDERS_FOR_ANCHOR_CUSTOMER + _BY_SKU_ONE)


def apply_overrides(catalog: dict, overrides: dict) -> list[str]:
    """Substitute override literals inside query/preQueries/postQueries.
    Returns the sorted names of entries that changed."""
    literals = overrides.get("literals", {})
    touched = []
    for name, entry in catalog.items():
        changed = False
        for key in ("query", "sql_equivalent"):
            text = entry.get(key, "")
            new = text
            for old, repl in literals.items():
                new = new.replace(old, repl)
            if new != text:
                entry[key] = new
                changed = True
        for key in ("preQueries", "postQueries"):
            if key in entry:
                new_list = []
                for text in entry[key]:
                    new = text
                    for old, repl in literals.items():
                        new = new.replace(old, repl)
                    new_list.append(new)
                    changed = changed or new != text
                entry[key] = new_list
        if changed:
            touched.append(name)
    return sorted(touched)


def _count_in(collection_file: Path, key: str, value: str) -> int:
    n = 0
    with gzip.open(collection_file, "rt", encoding="utf-8") as fh:
        for line in fh:
            if json.loads(line).get(key) == value:
                n += 1
    return n


def _exists(collection_file: Path, key: str, value: str) -> bool:
    return _count_in(collection_file, key, value) > 0


def recompute_expected(catalog: dict, overrides: dict, data_dir: Path) -> list[str]:
    """Rewrite expected_count for entries whose literals were patched, by
    probing the bundle. The anchor is read back out of the PATCHED query text
    (never assumed). Returns entry names that lacked enough info to recompute
    (bundle missing)."""
    literals = overrides.get("literals", {})

    bundle_ok = data_dir.is_dir() and any(data_dir.glob("*.ndjson.gz"))
    skipped: list[str] = []
    for name in sorted(_RECOMPUTED):
        entry = catalog.get(name)
        if entry is None:
            continue
        # Only touch entries we actually patched (their text now contains the
        # NEW literal) — the others' suite-stamped counts stand.
        was_patched = any(v in json.dumps(entry) for v in literals.values())
        if not was_patched:
            continue
        entry.pop("expected_first_rows_hash", None)
        if not bundle_ok:
            entry.pop("expected_count", None)
            skipped.append(name)
            continue
        query = entry.get("query", "")
        if name in _BY_ID_ONE:
            coll = "customers" if name.startswith("customers") else "orders"
            anchor = _extract(query, r"_id = '([^']+)'")
            entry["expected_count"] = (
                1 if anchor and _exists(data_dir / f"{coll}.ndjson.gz", "_id", anchor) else 0)
        elif name in _BY_SKU_ONE:
            anchor = _extract(query, r"sku = '([^']+)'")
            entry["expected_count"] = (
                1 if anchor and _exists(data_dir / "products.ndjson.gz", "sku", anchor) else 0)
        elif name in _ITEMS_FOR_ANCHOR_ORDER:
            anchor = _extract(query, r"order_id = '([^']+)'")
            entry["expected_count"] = _count_in(data_dir / "order_items.ndjson.gz",
                                                "order_id", anchor) if anchor else 0
        elif name in _ORDERS_FOR_ANCHOR_CUSTOMER:
            anchor = _extract(query, r"c\._id = '([^']+)'") or _extract(query, r"_id = '([^']+)'")
            entry["expected_count"] = _count_in(data_dir / "orders.ndjson.gz",
                                                "customer_id", anchor) if anchor else 0
    return skipped


def _extract(text: str, pattern: str) -> str | None:
    import re
    m = re.search(pattern, text)
    return m.group(1) if m else None


def main() -> int:
    if len(sys.argv) < 3:
        sys.exit(__doc__)
    catalog_path = Path(sys.argv[1])
    overrides = json.loads(Path(sys.argv[2]).read_text())
    data_dir = Path(sys.argv[3]) if len(sys.argv) > 3 else None

    catalog = json.loads(catalog_path.read_text())
    touched = apply_overrides(catalog, overrides)
    if data_dir is not None:
        skipped = recompute_expected(catalog, overrides, data_dir)
    else:
        skipped = []
    catalog_path.write_text(json.dumps(catalog, indent=2) + "\n")

    print(f"{catalog_path.name}: patched literals in {len(touched)} entries")
    if skipped:
        print(f"WARNING: no bundle at {data_dir} — {len(skipped)} patched entries lost "
              f"expected_count (run prepare_data.py first, then sync_benchmarks.sh)",
              file=sys.stderr)
    return 0


if __name__ == "__main__":
    sys.exit(main())
