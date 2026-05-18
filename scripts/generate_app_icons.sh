#!/usr/bin/env bash
# Regenerate macOS / Windows launcher icons from assets/icon/easyTerm.png.
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
SOURCE="$ROOT/assets/icon/easyTerm.png"
MACOS_DIR="$ROOT/macos/Runner/Assets.xcassets/AppIcon.appiconset"
WIN_ICO="$ROOT/windows/runner/resources/app_icon.ico"

if [[ ! -f "$SOURCE" ]]; then
  echo "Missing source icon: $SOURCE" >&2
  exit 1
fi

python3 - "$SOURCE" "$MACOS_DIR" "$WIN_ICO" <<'PY'
import sys
from pathlib import Path

from PIL import Image

SOURCE = Path(sys.argv[1])
MACOS_DIR = Path(sys.argv[2])
WIN_ICO = Path(sys.argv[3])
TARGET = 1024


def trim_alpha(img: Image.Image) -> Image.Image:
    rgba = img.convert("RGBA")
    bbox = rgba.getbbox()
    return rgba.crop(bbox) if bbox else rgba


def cover_square(img: Image.Image, size: int) -> Image.Image:
    """Scale to fill a square canvas, center-crop overflow (no letterboxing)."""
    w, h = img.size
    scale = max(size / w, size / h)
    resized = img.resize(
        (max(1, round(w * scale)), max(1, round(h * scale))),
        Image.Resampling.LANCZOS,
    )
    rw, rh = resized.size
    left = (rw - size) // 2
    top = (rh - size) // 2
    return resized.crop((left, top, left + size, top + size))


base = cover_square(trim_alpha(Image.open(SOURCE)), TARGET)

for edge in (16, 32, 64, 128, 256, 512, 1024):
    out = MACOS_DIR / f"app_icon_{edge}.png"
    if edge == TARGET:
        icon = base
    else:
        icon = base.resize((edge, edge), Image.Resampling.LANCZOS)
    icon.save(out)

sizes = [(16, 16), (32, 32), (48, 48), (64, 64), (128, 128), (256, 256)]
base.save(WIN_ICO, format="ICO", sizes=sizes)

print(f"Wrote {MACOS_DIR}/app_icon_*.png")
print(f"Wrote {WIN_ICO}")
PY

echo "Updated macOS AppIcon.appiconset and Windows app_icon.ico"
echo "Rebuild the app (flutter clean && flutter run) to refresh the dock/taskbar icon."
