#!/usr/bin/env bash
# ipa-rebrand.sh
# Downloads every .ipa from release FROM_TAG, rebrands it, uploads to release TO_TAG.

set -euo pipefail

### ===== SETTINGS (edit these, or pass as environment variables) ====
REPO="${REPO:-USERNAME/REPO}"
FROM_TAG="${FROM_TAG:-V.1}"
TO_TAG="${TO_TAG:-V.5}"
NEW_NAME="${NEW_NAME:-My App}"            # new app name
NEW_LOGO="${NEW_LOGO:-logo.png}"          # app icon (opaque PNG, 1024x1024)
MENU_TITLE="${MENU_TITLE:-My Mod Menu}"   # replaces "Made for iOSGods.com" (max 20 chars)
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

resize() { # src w h dst (Pillow)
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
import sys, os, re, io, base64, struct, zlib, plistlib, shutil
from PIL import Image

app, title, icon_path = sys.argv[1:4]
debug_dir = sys.argv[4] if len(sys.argv) > 4 else ''

if not title.strip():
    title = "My Mod Menu"

MACHO = (b'\xcf\xfa\xed\xfe', b'\xca\xfe\xba\xbe', b'\xbe\xba\xfe\xca')
B64 = re.compile(rb'iVBORw0KGgo[A-Za-z0-9+/]{200,}={0,2}')
PNG_SIG = b'\x89PNG\r\n\x1a\n'
PNG_END = b'IEND\xaeB`\x82'
CTX = re.compile(rb'[\x20-\x7e]{0,40}(?:gods|made for|multiplier)[\x20-\x7e]{0,40}', re.I)

def chunk(t, d):
    return struct.pack('>I', len(d)) + t + d + struct.pack('>I', zlib.crc32(t + d) & 0xffffffff)

def png_size(blob):
    i = blob.find(b'IHDR')
    if i < 0 or len(blob) < i + 12:
        return None
    w, h = struct.unpack('>II', blob[i+4:i+12])
    if 16 <= w <= 700 and 16 <= h <= 700 and 300 <= len(blob) <= 400000:
        return w, h
    return None

def looks_like_icon(blob):
    try:
        im = Image.open(io.BytesIO(blob)).convert('RGBA')
    except Exception:
        return True
    total = im.width * im.height
    opaque = sum(im.getchannel('A').histogram()[129:])
    colors = im.convert('RGB').getcolors(maxcolors=1 << 24) or []
    return opaque >= 0.25 * total and len(colors) >= 30

def make_png(target, w, h):
    src = Image.open(icon_path).convert('RGBA')
    s = 1.0
    while True:
        nw, nh = max(16, int(w * s)), max(16, int(h * s))
        small = src.resize((nw, nh), Image.LANCZOS)
        for im in (small, small.quantize(colors=128, method=Image.FASTOCTREE)):
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

def patch_cstr(buf, target_bytes, new_str):
    """Replaces C-strings in-place up to the null byte without breaking binary offsets."""
    count = 0
    idx = 0
    tb = new_str.encode('utf-8')
    while True:
        pos = buf.find(target_bytes, idx)
        if pos < 0:
            break
        end = buf.find(b'\x00', pos)
        if end < 0 or end - pos > 60:
            end = pos + len(target_bytes)
        avail = end - pos
        rep = tb[:avail].ljust(avail, b' ')
        buf[pos:end] = rep
        count += 1
        idx = end
    return count

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
ctx_lines = []
for p in files:
    rel = os.path.relpath(p, app)
    is_main = (rel == main_exe)
    with open(p, 'rb') as f:
        data = f.read()

    low = data.lower()
    if debug_dir and not is_main and len(data) < 60_000_000 and (
            p.endswith('.dylib') or b'gods' in low or b'multiplier' in low):
        os.makedirs(debug_dir, exist_ok=True)
        shutil.copy(p, os.path.join(debug_dir, rel.replace('/', '__')))
    for m in list(CTX.finditer(data))[:6]:
        ctx_lines.append(f"     {rel}: {m.group().decode('ascii', 'replace')}")

    new = bytearray(data)
    t_hits = 0

    # 1) Patch all standard & format-string variations of "Made for iOSGods.com"
    for pat in (
        b"Made for iOSGods.com",
        b"Made for iosgods.com",
        b"Made for %@!",
        b"Made for %@",
    ):
        t_hits += patch_cstr(new, pat, title)

    # 2) Handle split strings ("Made for " + "iOSGods.com")
    if t_hits == 0 and (b"iOSGods.com" in new or b"iosgods.com" in new):
        tb = title.encode('utf-8')
        if b"Made for " in new and len(tb) > 11:
            p1 = tb[:9].ljust(9, b' ')
            p2 = tb[9:20].ljust(11, b' ')
            new = bytearray(bytes(new).replace(b"Made for ", p1).replace(b"iOSGods.com", p2).replace(b"iosgods.com", p2))
            t_hits += 1
        else:
            new = bytearray(bytes(new).replace(b"Made for ", b" " * 9))
            t_hits += patch_cstr(new, b"iOSGods.com", title)
            t_hits += patch_cstr(new, b"iosgods.com", title)

    # 3) Handle UTF-16LE encoded strings
    old16 = "Made for iOSGods.com".encode('utf-16-le')
    if old16 in new:
        rep16 = title[:20].ljust(20).encode('utf-16-le')
        new = bytearray(bytes(new).replace(old16, rep16))
        t_hits += 1

    # 4) Handle Base64 encoded "Made for iOSGods.com" (TWFkZSBmb3IgaU9TR29kcy5jb20=)
    b64_old = base64.b64encode(b"Made for iOSGods.com")
    if b64_old in new:
        b64_new = base64.b64encode(title[:20].ljust(20).encode('utf-8'))
        if len(b64_new) == len(b64_old):
            new = bytearray(bytes(new).replace(b64_old, b64_new))
            t_hits += 1

    titles += t_hits

    # --- Find & Patch Icons ---
    b64s = []
    for m in set(B64.findall(bytes(new))):
        try:
            orig = base64.b64decode(m, validate=True)
        except Exception:
            continue
        wh = png_size(orig)
        if wh and looks_like_icon(orig):
            b64s.append((m, orig, wh))
    raws = [r for r in raw_pngs(bytes(new)) if looks_like_icon(bytes(new[r[0]:r[1]]))]

    is_menu_bin = (b'modslider' in low or b'iosgods' in low or b'multiplier' in low or t_hits > 0) and b'igamegod' not in low
    if is_menu_bin and not (is_main and icons > 0):
        for m, orig, (w, h) in b64s:
            try:
                png = make_png(len(orig), w, h)
                if png is not None:
                    nb = base64.b64encode(png)
                    if len(nb) == len(m):
                        new = bytearray(bytes(new).replace(m, nb))
                        icons += 1
            except Exception as ex:
                print("  icon patch skipped (base64) in", rel, "->", repr(ex))
        for s0, e0, w, h in raws:
            try:
                png = make_png(e0 - s0, w, h)
                if png is not None:
                    new[s0:e0] = png
                    icons += 1
            except Exception as ex:
                print("  icon patch skipped (raw) in", rel, "->", repr(ex))

    if bytes(new) != data:
        with open(p, 'wb') as f:
            f.write(bytes(new))
        print(f"  [Patched {rel}] title hits: {t_hits}, icons patched: {icons}", flush=True)

print(f"  Mach-O files scanned: {len(files)}")
print(f"  menu title patched: {titles} place(s), menu icon patched: {icons} place(s)")
if titles == 0:
    print("  !! title not found. Text pieces seen in the code (gods / made for / multiplier):")
    for l in ctx_lines[:40]:
        print(l)
PY

echo "== Downloading IPAs from $FROM_TAG"
gh release download "$FROM_TAG" -R "$REPO" -p "*.ipa" -D "$WORK/in"

for ipa in "$WORK"/in/*.ipa; do
  fname="$(basename "$ipa")"
  echo "== Processing $fname"
  T="$WORK/tmp"; rm -rf "$T"; mkdir "$T"
  unzip -q "$ipa" -d "$T"
  APP="$(ls -d "$T"/Payload/*.app | head -n1)"

  # 1) App name + Force custom icon in Info.plist
  resize "$NEW_LOGO" 120 120 "$APP/AppIcon60x60@2x.png"
  resize "$NEW_LOGO" 180 180 "$APP/AppIcon60x60@3x.png"
  resize "$NEW_LOGO" 152 152 "$APP/AppIcon76x76@2x~ipad.png"

  python3 - "$APP/Info.plist" "$NEW_NAME" <<'PY'
import plistlib, sys
path, name = sys.argv[1:3]
with open(path, 'rb') as f:
    d = plistlib.load(f)
d['CFBundleDisplayName'] = name
d['CFBundleName'] = name
icon_dict = {
    'CFBundlePrimaryIcon': {
        'CFBundleIconFiles': ['AppIcon60x60', 'AppIcon76x76'],
        'UIPrerenderedIcon': True
    }
}
d['CFBundleIcons'] = icon_dict
d['CFBundleIcons~ipad'] = icon_dict
with open(path, 'wb') as f:
    plistlib.dump(d, f, fmt=plistlib.FMT_BINARY)
PY

  # 2) App icon (replace all existing icon PNGs at their exact dimensions)
  while IFS= read -r -d '' f; do
    read -r w h < <(python3 -c "
import struct, sys
b = open(sys.argv[1], 'rb').read(64)
i = b.find(b'IHDR')
if i >= 0:
    print(*struct.unpack('>II', b[i+4:i+12]))
else:
    print(180, 180)
" "$f")
    resize "$NEW_LOGO" "$w" "$h" "$f.new" && mv "$f.new" "$f"
  done < <(find "$APP" -maxdepth 1 -type f \( -iname "AppIcon*.png" -o -iname "Icon*.png" \) -print0)

  # 3) Mod menu: title + floating icon (inside the dylib / binary)
  python3 "$WORK/patch_menu.py" "$APP" "$MENU_TITLE" "$MENU_ICON" "$WORK/debug"

  # 4) Red -> white (text resource files + binary/XML plists)
  for c in "${RED_HEXES[@]}"; do
    find "$APP" -type f \( -name "*.json" -o -name "*.css" -o -name "*.js" \
      -o -name "*.html" -o -name "*.strings" \) \
      -exec perl -pi -e "s/#$c/#$WHITE_HEX/gi" {} +
  done

  python3 - "$APP" "$WHITE_HEX" "${RED_HEXES[@]}" <<'PY'
import os, sys, re, plistlib

app, white, reds = sys.argv[1], sys.argv[2], sys.argv[3:]
pattern = re.compile(r'#(' + '|'.join(re.escape(r) for r in reds) + r')\b', re.I)

def replace_in_obj(obj):
    changed = False
    if isinstance(obj, dict):
        for k, v in obj.items():
            nv, c = replace_in_obj(v)
            if c:
                obj[k] = nv
                changed = True
    elif isinstance(obj, list):
        for i, v in enumerate(obj):
            nv, c = replace_in_obj(v)
            if c:
                obj[i] = nv
                changed = True
    elif isinstance(obj, str):
        new_s, n = pattern.subn('#' + white, obj)
        if n > 0:
            return new_s, True
    return obj, changed

for root, _, names in os.walk(app):
    for n in names:
        if not n.endswith('.plist') or n == 'Info.plist':
            continue
        p = os.path.join(root, n)
        try:
            with open(p, 'rb') as f:
                raw = f.read()
            is_bin = raw.startswith(b'bplist')
            data = plistlib.loads(raw)
            data, changed = replace_in_obj(data)
            if changed:
                with open(p, 'wb') as f:
                    plistlib.dump(data, f, fmt=plistlib.FMT_BINARY if is_bin else plistlib.FMT_XML)
        except Exception:
            pass
PY

  # 5) Re-pack
  (cd "$T" && zip -qry "$WORK/out/$fname" Payload)
done

echo "== Uploading to $TO_TAG"
gh release view "$TO_TAG" -R "$REPO" >/dev/null 2>&1 || \
  gh release create "$TO_TAG" -R "$REPO" -t "$TO_TAG" -n "Rebranded IPAs"
gh release upload "$TO_TAG" "$WORK"/out/*.ipa -R "$REPO" --clobber

rm -rf "$WORK/tmp"
echo "Done."
