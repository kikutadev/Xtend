#!/bin/bash
# Seed a previously installed Xtend app on a Simulator with the public
# x-home-anchor release ZIP. Does not erase app data, cookies, or extensions.
set -euo pipefail

project_dir="$(cd "$(dirname "$0")/.." && pwd)"
device="${1:-booted}"
zip_file="${2:-$project_dir/.build/x-home-anchor.zip}"

if [[ ! -f "$zip_file" ]]; then
  echo "Missing extension ZIP: $zip_file" >&2
  exit 1
fi

app_data="$(xcrun simctl get_app_container "$device" org.example.xtend data)"
extensions="$app_data/Library/Application Support/Extensions"
destination="$extensions/x-home-anchor"
if [[ -e "$destination" ]]; then
  echo "Already installed; no changes made: $destination"
  exit 0
fi

mkdir -p "$extensions"
temporary="$(mktemp -d "$extensions/.anchor-repro.XXXXXXXX")"
trap 'rm -rf "$temporary"' EXIT

python3 - "$zip_file" "$temporary" <<'PY'
from pathlib import Path, PurePosixPath
import json
import stat
import sys
import zipfile

source = Path(sys.argv[1])
destination = Path(sys.argv[2])
with zipfile.ZipFile(source) as archive:
    entries = archive.infolist()
    if len(entries) > 500 or sum(e.file_size for e in entries) > 128 * 1024 * 1024:
        raise SystemExit("Refusing oversized or excessive ZIP entries")
    for entry in entries:
        name = PurePosixPath(entry.filename)
        if name.is_absolute() or ".." in name.parts or "\\" in entry.filename:
            raise SystemExit(f"Refusing unsafe ZIP path: {entry.filename}")
        if stat.S_IFMT(entry.external_attr >> 16) == stat.S_IFLNK:
            raise SystemExit(f"Refusing ZIP symbolic link: {entry.filename}")
    manifest = json.loads(archive.read("manifest.json"))
    if manifest.get("manifest_version") != 3 or manifest.get("name") != "X ホームの閲覧位置":
        raise SystemExit("Not a supported x-home-anchor build")
    if "content.js" not in archive.namelist():
        raise SystemExit("No compiled content.js")
    archive.extractall(destination)
(destination / ".xtend-headless-repro").write_text("Installed from local x-home-anchor ZIP for Simulator validation.\n")
print(f"Validated x-home-anchor {manifest.get('version', 'unknown')}")
PY

if [[ -e "$destination" ]]; then
  echo "Extension appeared during setup; refusing to replace it" >&2
  exit 1
fi
mv "$temporary" "$destination"
trap - EXIT

echo "Installed into existing Xtend data (login and WebKit storage untouched)."
echo "Reproducible setup: scripts/seed-simulator-x-home-anchor.sh $device $zip_file"
