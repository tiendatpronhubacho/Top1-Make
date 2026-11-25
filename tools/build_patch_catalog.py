#!/usr/bin/env python3
"""Build and verify PatchCatalog.dat from the current Patches/ directory.

Replace a patch by deleting the old file and placing the new .3105/.3106 file
under the exact same filename. Every Codemagic workflow runs this script before
Xcode, so the catalog is regenerated from the replacement bytes on each build.
"""
from pathlib import Path
import hashlib
import os
import plistlib
import unicodedata

ROOT = Path(__file__).resolve().parents[1]
SOURCE = ROOT / "Patches"
TARGET = ROOT / "PatchCatalog.dat"
MAGIC = b"3105PATCH\0"
MIN_READ_SCHEMA = 1
MAX_READ_SCHEMA = 9

if not SOURCE.is_dir():
    raise SystemExit(f"Patches directory not found: {SOURCE}")


def catalog_name(name: str) -> str:
    # Repair legacy ZIP entries whose UTF-8 names were decoded as CP437.
    try:
        repaired = name.encode("cp437").decode("utf-8")
        if any(ch in name for ch in "╠╡╢╣╤╥╦╧╨╩╪╫╬"):
            name = repaired
    except (UnicodeEncodeError, UnicodeDecodeError):
        pass
    return unicodedata.normalize("NFC", name)


packages = {}
metadata = {}
for path in sorted(SOURCE.iterdir(), key=lambda item: item.name.casefold()):
    if path.is_symlink() or not path.is_file():
        continue
    if path.suffix.lower() not in {".3105", ".3106"}:
        continue

    filename = catalog_name(path.name)
    if filename in packages:
        raise SystemExit(f"Duplicate patch filename after Unicode normalization: {filename}")

    data = path.read_bytes()
    if len(data) <= len(MAGIC) or not data.startswith(MAGIC):
        raise SystemExit(f"Invalid patch format: {path.name}")
    try:
        envelope = plistlib.loads(data[len(MAGIC):])
    except Exception as error:
        raise SystemExit(f"Invalid patch envelope in {path.name}: {error}")

    schema = envelope.get("schemaVersion") if isinstance(envelope, dict) else None
    if not isinstance(schema, int) or not (MIN_READ_SCHEMA <= schema <= MAX_READ_SCHEMA):
        raise SystemExit(
            f"Unsupported patch schema in {path.name}: {schema!r}; "
            f"this app supports {MIN_READ_SCHEMA}..{MAX_READ_SCHEMA}"
        )
    for required in ("packageID", "isPasswordProtected", "keyFingerprint", "encryptedPayload"):
        if required not in envelope:
            raise SystemExit(f"Missing {required} in patch: {path.name}")

    packages[filename] = data
    metadata[filename] = (schema, hashlib.sha256(data).hexdigest())

if not packages:
    raise SystemExit("No .3105/.3106 patch packages found in Patches/")

payload = plistlib.dumps(packages, fmt=plistlib.FMT_BINARY, sort_keys=True)
verified = plistlib.loads(payload)
if verified != packages:
    raise SystemExit("PatchCatalog.dat in-memory verification failed")

temporary = TARGET.with_name(TARGET.name + ".tmp")
temporary.write_bytes(payload)
os.replace(temporary, TARGET)

# Verify the actual file written to disk, not just the in-memory serialization.
written = plistlib.loads(TARGET.read_bytes())
if written != packages:
    raise SystemExit("PatchCatalog.dat on-disk verification failed")

print(f"Generated {TARGET.name}: {len(packages)} patches, {len(payload):,} bytes")
for filename in sorted(packages, key=str.casefold):
    schema, digest = metadata[filename]
    print(f"  schema v{schema}: {filename} (SHA-256 {digest[:16]}…)")
