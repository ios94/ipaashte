#!/usr/bin/env bash
# ipa-rebrand.sh
# Downloads every .ipa from release FROM_TAG, rebrands it, uploads to release TO_TAG.
#  - app name + app icon
#  - mod-menu title ("Made for iOSGods.com") + floating menu icon (binary patch)
#  - red -> white in text resource files

set -euo pipefail

### ===== SETTINGS (edit these, or pass as environment variables) ====
REPO="${REPO:-USERNAME/REPO}"
FROM_TAG="${FROM_TAG:-V.1}"
TO_TAG="${TO_TAG:-V.5}"
NEW_NAME="${NEW_NAME:-My App}"            # new app name
NEW_LOGO="${NEW_LOGO:-logo.png}"          # app icon (opaque PNG, 1024x1024)
MENU_TITLE="${MENU_TITLE:-}"              # replaces "Made for iOSGods.com" (max 20 chars)
MENU_ICON="${MENU_ICON:-menu_icon.png}"   # floating menu icon (transparent PNG)
read -r -a RED_HEXES <<< "${RED_HEXES:-FF0000 E50914 FF3B30}"   # reds to replace (no #)
WHITE_HEX="FFFFFF"
### =================================================================

for cmd in gh zip unzip python3 perl; do
  command -v "$cmd" >/dev/null || { echo "Missing: $cmd"; exit 1; }
done
python3 -c "import PIL" 2>/dev/null || pip3 install --quiet pillow
[ -f "$NEW_LOGO" ] || { echo "Logo not found: $NEW_LOGO"; exit 1; }
[ -f "$MENU_ICON" ] || MENU_ICON="$NEW_LOGO"

resize() { # src w h dst  (Pillow, works on any system)
  python3 - "$1" "$2" "$3" "$4" <<'PYR'
import sys
from PIL import Image
src, w, h, dst = sys.argv[1], int(sys.argv[2]), int(sys.argv[3]), sys.argv[4]
Image.open(src).convert("RGBA").resize((w, h), Image.LANCZOS).save(dst, "PNG")
PYR
}

WORK="$(pwd)/work"
rm -rf "$WORK"; mkdir -p "$WORK/in" "$WORK/out"

# ---- binary patcher for the mod menu (title + floating icon) ----
cat > "$WORK/patch_menu.py" <<'PY'
import sys, os, re, io, base64, struct, zlib, plistlib
from PIL import Image

app, title, icon_path = sys.argv[1:4]
OLD = b"Made for iOSGods.com"
OLD16 = OLD.decode().encode('utf-16-le')
MACHO = (b'\xcf\xfa\xed\xfe', b'\xca\xfe\xba\xbe', b'\xbe\xba\xfe\xca')
B64 = re.compile(rb'iVBORw0KGgo[A-Za-z0-9+/]{200,}={0,2}')
PNG_SIG = b'\x89PNG\r\n\x1a\n'
PNG_END = b'IEND\xaeB`\x82'

def chunk(t, d):
    return struct.pack('>I', len(d)) + t + d + struct.pack('>I', zlib.crc32(t + d) & 0xffffffff)

def png_size(blob):
    i = blob.find(b'IHDR')
    if i < 0 or len(blob) < i + 12:
        return None
    w, h = struct.unpack('>II', blob[i+4:i+12])
    # a menu icon is small; ignore anything else (textures, bogus matches)
    if 16 <= w <= 700 and 16 <= h <= 700 and 300 <= len(blob) <= 400000:
        return w, h
    return None

def make_png(target, w, h):
    """PNG of exactly `target` bytes (so the surrounding data keeps its length)."""
    src = Image.open(icon_path).convert('RGBA')
    s = 1.0
    while True:
        nw, nh = max(16, int(w * s)), max(16, int(h * s))
        im = src.resize((nw, nh), Image.LANCZOS).quantize(colors=128, method=Image.FASTOCTREE)
        buf = io.BytesIO(); im.save(buf, 'PNG', optimize=True)
        b = buf.getvalue()
        if len(b) == target:
            return b
        if len(b) + 20 <= target:
            pad = target - len(b) - 20
            return b[:-12] + chunk(b'tEXt', b'Comment\x00' + b'x' * pad) + b[-12:]
        if nw <= 16:
            return None
        s *= 0.85

def raw_pngs(data):
    out, i = [], 0
    while True:
        s = data.find(PNG_SIG, i)
        if s < 0:
            break
        e = data.find(PNG_END, s)
        if e < 0:
            break
        e += len(PNG_END)
        wh = png_size(data[s:e])
        if wh:
            out.append((s, e, wh[0], wh[1]))
        i = e
    return out

# main executable is handled last (the menu normally lives in a dylib)
try:
    with open(os.path.join(app, 'Info.plist'), 'rb') as f:
        main_exe = plistlib.load(f).get('CFBundleExecutable', '')
except Exception:
    main_exe = ''

files = []
for root, _, names in os.walk(app):
    for n in names:
        p = os.path.join(root, n)
        if os.path.islink(p) or not os.path.isfile(p):
            continue
        with open(p, 'rb') as f:
            if f.read(4) in MACHO:
                files.append(p)
files.sort(key=lambda p: (os.path.relpath(p, app) == main_exe, p))

titles = icons = 0
for p in files:
    rel = os.path.relpath(p, app)
    is_main = (rel == main_exe)
    with open(p, 'rb') as f:
        data = f.read()
    new = bytearray(data)
    info = []

    # --- title (ascii and utf-16) ---
    for old, enc in ((OLD, 'ascii'), (OLD16, 'utf-16-le')):
        if old in new:
            info.append(f"title[{enc}] x{new.count(old)}")
            if title:
                t = title.encode('utf-8' if enc == 'ascii' else enc)
                sp = b' ' if enc == 'ascii' else b' \x00'
                if len(t) > len(old):
                    sys.exit("MENU_TITLE too long (max 20 characters)")
                new = bytearray(bytes(new).replace(old, t + sp * ((len(old) - len(t)) // len(sp))))
                titles += 1

    # find icon candidates first (printed even if patching fails)
    b64s = []
    for m in set(B64.findall(bytes(new))):
        try:
            orig = base64.b64decode(m, validate=True)
        except Exception:
            continue
        wh = png_size(orig)
        if wh:
            b64s.append((m, orig, wh))
    b64s.sort(key=lambda x: len(x[0]), reverse=True)
    raws = raw_pngs(bytes(new))
    if b64s:
        info.append("base64-png " + ",".join(f"{w}x{h}" for _, _, (w, h) in b64s[:6]))
    if raws:
        info.append("raw-png " + ",".join(f"{w}x{h}({e-s}B)" for s, e, w, h in raws[:6]))
    if info:
        print(f"  [{rel}] " + "; ".join(info), flush=True)

    # --- icon (the main executable only if no dylib had one) ---
    if not (is_main and icons > 0):
        try:
            if b64s:
                m, orig, (w, h) = b64s[0]
                png = make_png(len(orig), w, h)
                if png is not None:
                    nb = base64.b64encode(png)
                    if len(nb) == len(m):
                        new = bytearray(bytes(new).replace(m, nb))
                        icons += 1
            elif raws:
                s0, e0, w, h = max(raws, key=lambda r: r[1] - r[0])
                png = make_png(e0 - s0, w, h)
                if png is not None:
                    new[s0:e0] = png
                    icons += 1
        except Exception as ex:
            print("  menu icon patch skipped in", rel, "->", repr(ex))

    if bytes(new) != data:
        with open(p, 'wb') as f:
            f.write(bytes(new))

print(f"  Mach-O files scanned: {len(files)}")
print(f"  menu title patched: {titles} place(s), menu icon patched: {icons} place(s)")
if titles == 0 or icons == 0:
    print("  !! not everything was found. Files containing 'iosgods' (any case):")
    hits = 0
    for root, _, names in os.walk(app):
        for n in names:
            p = os.path.join(root, n)
            if os.path.islink(p) or not os.path.isfile(p) or os.path.getsize(p) > 200_000_000:
                continue
            with open(p, 'rb') as f:
                d = f.read().lower()
            if b'iosgods' in d or 'iosgods'.encode('utf-16-le') in d:
                print("     ", os.path.relpath(p, app)); hits += 1
    if hits == 0:
        print("      none -> the text is hidden/encrypted inside the code (needs the source or the dylib)")

PY

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

  # 2) App icon (keeps each icon's original size)
  while IFS= read -r -d '' f; do
    read -r w h < <(python3 -c "
import struct, sys
b = open(sys.argv[1], 'rb').read(64)
i = b.find(b'IHDR')
print(*struct.unpack('>II', b[i+4:i+12]))
" "$f")
    resize "$NEW_LOGO" "$w" "$h" "$f.new" && mv "$f.new" "$f"
  done < <(find "$APP" -maxdepth 1 -type f \( -iname "AppIcon*.png" -o -iname "Icon*.png" \) -print0)

  # 3) Mod menu: title + floating icon (inside the dylib / binary)
  python3 "$WORK/patch_menu.py" "$APP" "$MENU_TITLE" "$MENU_ICON"

  # 4) Red -> white (text resource files only)
  for c in "${RED_HEXES[@]}"; do
    find "$APP" -type f \( -name "*.json" -o -name "*.css" -o -name "*.js" \
      -o -name "*.html" -o -name "*.plist" -o -name "*.strings" \) \
      -exec perl -pi -e "s/#$c/#$WHITE_HEX/gi" {} +
  done

  # 5) Re-pack
  (cd "$T" && zip -qry "$WORK/out/$fname" Payload)
done

echo "== Uploading to $TO_TAG"
gh release view "$TO_TAG" -R "$REPO" >/dev/null 2>&1 || \
  gh release create "$TO_TAG" -R "$REPO" -t "$TO_TAG" -n "Rebranded IPAs"
gh release upload "$TO_TAG" "$WORK"/out/*.ipa -R "$REPO" --clobber

rm -rf "$WORK/tmp"
echo "Done."
