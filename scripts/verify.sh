#!/bin/zsh
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
APP_BINARY="$ROOT_DIR/build/CommandDash.app/Contents/MacOS/CommandDash"

cd "$ROOT_DIR"
./build.sh

file_output="$(file "$APP_BINARY")"
for arch in ${(z)${ARCHS:-arm64 x86_64}}; do
  if [[ "$file_output" != *"$arch"* ]]; then
    echo "Missing architecture: $arch"
    exit 1
  fi

  build_info="$(xcrun vtool -show-build -arch "$arch" "$APP_BINARY")"
  if [[ "$build_info" != *"minos 13.0"* ]]; then
    echo "Unexpected minimum macOS version for $arch"
    echo "$build_info"
    exit 1
  fi
done

if grep -R -n -E '/Users/[^/]+|/Volumes/[^/]+/[^/]+|gateway stop' Sources build.sh; then
  echo "Found a personal path or product-specific launcher command in publishable source."
  exit 1
fi

python3 - <<'PY'
from pathlib import Path
import hashlib
import json
import re
import subprocess

root = Path.cwd()
missing = []
readmes = sorted(root.glob("README*.md"))
for readme_path in readmes:
    readme = readme_path.read_text(encoding="utf-8")
    refs = re.findall(r'(?:src="|\]\()([^"\)]+)', readme)
    for ref in refs:
        if ref.startswith(("http://", "https://", "#", "mailto:")):
            continue
        path = ref.split("#", 1)[0]
        if path and not (root / path).exists():
            missing.append(f"{readme_path.name}: {path}")

if missing:
    raise SystemExit("Missing README assets:\n" + "\n".join(sorted(set(missing))))

tracked = subprocess.check_output(["git", "ls-files", "-z"]).decode("utf-8").split("\0")
non_ascii_names = [path for path in tracked if path and not path.isascii()]
if non_ascii_names:
    raise SystemExit("Tracked filenames must use ASCII names:\n" + "\n".join(non_ascii_names))

manifest_path = root / "docs/assets/readme/manifest.json"
manifest = json.loads(manifest_path.read_text(encoding="utf-8"))
asset_errors = []
for item in manifest["assets"]:
    path = root / item["path"]
    if not path.exists():
        asset_errors.append(f"Missing manifest asset: {item['path']}")
        continue
    data = path.read_bytes()
    digest = hashlib.sha256(data).hexdigest()
    if len(data) != item["bytes"]:
        asset_errors.append(f"Size mismatch: {item['path']}")
    if digest != item["sha256"]:
        asset_errors.append(f"SHA-256 mismatch: {item['path']}")

if asset_errors:
    raise SystemExit("\n".join(asset_errors))
PY

echo "Verification passed."
