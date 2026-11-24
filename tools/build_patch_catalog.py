#!/usr/bin/env python3
"""Build the single bundled PatchCatalog.dat resource from ./Patches."""
from pathlib import Path
import plistlib

root = Path(__file__).resolve().parents[1]
source = root / "Patches"
packages = {
    path.name: path.read_bytes()
    for path in sorted(source.iterdir(), key=lambda p: p.name.lower())
    if path.is_file() and path.suffix.lower() in {".3105", ".3106"}
}
if not packages:
    raise SystemExit("No .3105/.3106 patch packages found in Patches/")
(root / "PatchCatalog.dat").write_bytes(
    plistlib.dumps(packages, fmt=plistlib.FMT_BINARY, sort_keys=True)
)
print(f"Wrote PatchCatalog.dat with {len(packages)} packages")
