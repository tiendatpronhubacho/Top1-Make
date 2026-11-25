#!/usr/bin/env python3
"""Build and verify the bundled binary PatchCatalog.dat from ./Patches."""
from pathlib import Path
import plistlib
import os
import unicodedata

root = Path(__file__).resolve().parents[1]
source = root / "Patches"
target = root / "PatchCatalog.dat"

if not source.is_dir():
    raise SystemExit(f"Patches directory not found: {source}")

def catalog_name(name: str) -> str:
    # Some ZIP archives in this project contain legacy CP437-decoded UTF-8
    # filenames. Repair those names when possible, while preserving valid
    # native Unicode filenames.
    try:
        repaired = name.encode("cp437").decode("utf-8")
        if any(ch in name for ch in "╠╡╢╣╤╥╦╧╨╩╪╫╬"):
            name = repaired
    except (UnicodeEncodeError, UnicodeDecodeError):
        pass
    return unicodedata.normalize("NFC", name)

packages = {}
for path in sorted(source.iterdir(), key=lambda item: item.name.casefold()):
    if path.is_symlink() or not path.is_file():
        continue
    if path.suffix.lower() not in {".3105", ".3106"}:
        continue
    name = catalog_name(path.name)
    if name in packages:
        raise SystemExit(f"Duplicate patch filename after Unicode normalization: {name}")
    packages[name] = path.read_bytes()

if not packages:
    raise SystemExit("No .3105/.3106 patch packages found in Patches/")

payload = plistlib.dumps(packages, fmt=plistlib.FMT_BINARY, sort_keys=True)
verified = plistlib.loads(payload)
if verified != packages:
    raise SystemExit("PatchCatalog.dat verification failed")

temporary = target.with_name(target.name + ".tmp")
temporary.write_bytes(payload)
os.replace(temporary, target)

print(f"Wrote {target.name}: {len(packages)} patches, {len(payload):,} bytes")
for filename in sorted(packages, key=str.casefold):
    print(f"  - {filename}")
