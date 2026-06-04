#!/usr/bin/env python3
"""
Generates data/game/manifest.json — an explicit list of every .tres file the
Registry should load at runtime.

Why: in exported macOS builds, DirAccess.open("res://path/") + list_dir_begin()
is unreliable for listing files inside the PCK. The Registry reads this
manifest first so it knows exactly which paths to load via ResourceLoader,
which works on every platform.

Run this script any time you add, rename, or delete a .tres file in one of
the registered groups below:

    python3 tools/build_manifest.py
"""

import json
import os
import sys

REPO_ROOT = os.path.abspath(os.path.join(os.path.dirname(__file__), ".."))

# group_name -> directory (relative to repo root)
GROUPS = {
    "items":          "data/game/tarkon/items",
    "blocks":         "data/game/tarkon/blocks",
    "units":          "data/game/tarkon/units",
    "fluids":         "data/game/tarkon/fluids",
    "tiles":          "data/game/tarkon/tiles",
    "status_effects": "data/game/tarkon/status_effects",
    "sectors":        "data/game/tarkon/sectors",
    "planets":        "data/game/planets",
    "archives":       "data/game/tarkon/archives",
}

OUT_PATH = os.path.join(REPO_ROOT, "data/game/manifest.json")


def main() -> int:
    out: dict[str, list[str]] = {}
    total = 0
    for key, rel_dir in GROUPS.items():
        abs_dir = os.path.join(REPO_ROOT, rel_dir)
        if not os.path.isdir(abs_dir):
            print(f"WARN: directory missing: {rel_dir}", file=sys.stderr)
            out[key] = []
            continue
        files = sorted(f for f in os.listdir(abs_dir) if f.endswith(".tres"))
        out[key] = [f"res://{rel_dir}/{f}" for f in files]
        total += len(files)

    os.makedirs(os.path.dirname(OUT_PATH), exist_ok=True)
    # sort_keys keeps this byte-identical to the in-editor GDScript builder
    # (addons/manifest_builder), whose JSON.stringify sorts keys — so the two
    # generators never produce diff churn against each other.
    with open(OUT_PATH, "w", encoding="utf-8") as fh:
        json.dump(out, fh, indent=2, sort_keys=True)
        fh.write("\n")

    print(f"Wrote {OUT_PATH} ({total} entries across {len(GROUPS)} groups)")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
