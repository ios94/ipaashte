#!/usr/bin/env bash
# ipa-rebrand.sh
# Downloads every .ipa from release FROM_TAG, changes name + logo + red->white colors,
# re-zips them and uploads them to release TO_TAG.

set -euo pipefail

### ===== SETTINGS (edit these) =====================================
REPO="${REPO:-USERNAME/REPO}"
FROM_TAG="${FROM_TAG:-V.1}"
TO_TAG="${TO_TAG:-V.5}"
NEW_NAME="${NEW_NAME:-My App}"
NEW_LOGO="${NEW_LOGO:-logo.png}"
read -r -a RED_HEXES <<< "${RED_HEXES:-FF0000 E50914 FF3B30}"   # red colors to replace (without #)
WHITE_HEX="FFFFFF"                       # replacement color (same length as above!)
### =================================================================

for cmd in gh zip unzip python3 perl; do
  command -v "$cmd" >/dev/null || { echo "Missing: $cmd"; exit 1; }
done
[ -f "$NEW_LOGO" ] || { echo "Logo not found: $NEW_LOGO"; exit 1; }

IM="$(command -v magick || command -v convert || true)"
resize() { # src w h dst
  if command -v sips >/dev/null; then
    sips -z "$3" "$2" "$1" --out "$4" >/dev/null
  elif [ -n "$IM" ]; then
    "$IM" "$1" -resize "${2}x${3}!" "$4"
  else
    echo "Need sips (macOS) or ImageMagick"; exit 1
  fi
}

WORK="$(pwd)/work"
rm -rf "$WORK"; mkdir -p "$WORK/in" "$WORK/out"

echo "== Downloading IPAs from $FROM_TAG"
gh release download "$FROM_TAG" -R "$REPO" -p "*.ipa" -D "$WORK/in"

for ipa in "$WORK"/in/*.ipa; do
  fname="$(basename "$ipa")"
  echo "== Processing $fname"
  T="$WORK/tmp"; rm -rf "$T"; mkdir "$T"
  unzip -q "$ipa" -d "$T"
  APP="$(ls -d "$T"/Payload/*.app | head -n1)"

  # 1) App name
  python3 - "$APP/Info.plist" "$NEW_NAME" <<'PY'
import plistlib, sys
path, name = sys.argv[1:3]
with open(path, 'rb') as f:
    d = plistlib.load(f)
d['CFBundleDisplayName'] = name
d['CFBundleName'] = name
with open(path, 'wb') as f:
    plistlib.dump(d, f, fmt=plistlib.FMT_BINARY)
PY

  # 2) Logo / app icons (keeps each icon's original size)
  while IFS= read -r -d '' f; do
    read -r w h < <(python3 -c "
import struct, sys
b = open(sys.argv[1], 'rb').read(64)
i = b.find(b'IHDR')
print(*struct.unpack('>II', b[i+4:i+12]))
" "$f")
    resize "$NEW_LOGO" "$w" "$h" "$f.new" && mv "$f.new" "$f"
  done < <(find "$APP" -maxdepth 1 -type f \( -iname "AppIcon*.png" -o -iname "Icon*.png" \) -print0)

  # 3) Menu colors: red -> white (text resource files only)
  for c in "${RED_HEXES[@]}"; do
    find "$APP" -type f \( -name "*.json" -o -name "*.css" -o -name "*.js" \
      -o -name "*.html" -o -name "*.plist" -o -name "*.strings" \) \
      -exec perl -pi -e "s/#$c/#$WHITE_HEX/gi" {} +
  done

  # 4) Re-pack
  (cd "$T" && zip -qry "$WORK/out/$fname" Payload)
done

echo "== Uploading to $TO_TAG"
gh release view "$TO_TAG" -R "$REPO" >/dev/null 2>&1 || \
  gh release create "$TO_TAG" -R "$REPO" -t "$TO_TAG" -n "Rebranded IPAs"
gh release upload "$TO_TAG" "$WORK"/out/*.ipa -R "$REPO" --clobber

rm -rf "$WORK/tmp"
echo "Done."
