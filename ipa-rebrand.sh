#!/usr/bin/env bash
# ipa-rebrand.sh (Targeted iGameGod & Mod Menu Patcher)

set -euo pipefail

### ===== SETTINGS ====
REPO="${REPO:-USERNAME/REPO}"
FROM_TAG="${FROM_TAG:-V.1}"
TO_TAG="${TO_TAG:-V.5}"
NEW_NAME="${NEW_NAME:-My App}"
NEW_LOGO="${NEW_LOGO:-logo.png}"
MENU_TITLE="${MENU_TITLE:-Ashte Mod}"
MENU_ICON="${MENU_ICON:-menu_icon.png}"
MENU_COLOR_HEX="${MENU_COLOR_HEX:-1E64E8}" # Blue HEX (6 chars)
### ===================

for cmd in gh zip unzip python3 perl; do
  command -v "$cmd" >/dev/null || { echo "Missing: $cmd"; exit 1; }
done
python3 -c "import PIL" 2>/dev/null || pip3 install --quiet pillow
[ -f "$NEW_LOGO" ] || { echo "Logo not found: $NEW_LOGO"; exit 1; }
[ -f "$MENU_ICON" ] || MENU_ICON="$NEW_LOGO"

resize() {
  python3 - "$1" "$2" "$3" "$4" <<'PYR'
import sys
from PIL import Image
src, w, h, dst = sys.argv[1], int(sys.argv[2]), int(sys.argv[3]), sys.argv[4]
Image.open(src).convert("RGBA").resize((w, h), Image.LANCZOS).save(dst, "PNG")
PYR
}

WORK="$(pwd)/work"
rm -rf "$WORK"; mkdir -p "$WORK/in" "$WORK/out"

# ---- Binary Patcher targeting iGameGod and Mod Menu dylibs ----
cat > "$WORK/patch_menu.py" <<'PY'
import sys, os, re, io, base64, struct, zlib, plistlib, shutil
from PIL import Image

app, title, icon_path, hex_col = sys.argv[1:5]
debug_dir = sys.argv[5] if len(sys.argv) > 5 else ''

if not title.strip():
    title = "Ashte Mod"

hex_col = hex_col.lstrip('#').strip().upper()
if len(hex_col) != 6:
    hex_col = "1E64E8"

# Calculate darker hex for header bars
r = max(0, int(int(hex_col[0:2], 16) * 0.78))
g = max(0, int(int(hex_col[2:4], 16) * 0.78))
b = max(0, int(int(hex_col[4:6], 16) * 0.78))
hdr_hex = f"{r:02X}{g:02X}{b:02X}"

MACHO = (b'\xcf\xfa\xed\xfe', b'\xca\xfe\xba\xbe', b'\xbe\xba\xfe\xca')
B64 = re.compile(rb'iVBORw0KGgo[A-Za-z0-9+/]{100,}={0,2}')
PNG_SIG = b'\x89PNG\r\n\x1a\n'
PNG_END = b'IEND\xaeB`\x82'

# Only ignore standard ad/analytics SDKs (DO NOT ignore iGameGod)
IGNORE_SDKS = (
    'adjustsdk', 'applovin', 'bidmachine', 'fbsdk', 'helpshift',
    'hyprmx', 'ironsource', 'unityads', 'vungle', 'chartboost',
    'admob', 'googlemobileads', 'crashlytics', 'firebase', 'appsflyer'
)

def chunk(t, d):
    return struct.pack('>I', len(d)) + t + d + struct.pack('>I', zlib.crc32(t + d) & 0xffffffff)

def png_size(blob):
    i = blob.find(b'IHDR')
    if i < 0 or len(blob) < i + 12:
        return None
    w, h = struct.unpack('>II', blob[i+4:i+12])
    if 16 <= w <= 700 and 16 <= h <= 700 and 200 <= len(blob) <= 500000:
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
    return opaque >= 0.20 * total and len(colors) >= 20

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

def safe_patch_title(buf, new_title):
    hits = 0
    tb = new_title.encode('utf-8')

    # 1) Exact 20-byte replacement for "Made for iOSGods.com"
    rep20 = tb[:20].ljust(20, b' ')
    for pat in (b"Made for iOSGods.com", b"made for iosgods.com"):
        if pat in buf:
            hits += buf.count(pat)
            buf[:] = bytes(buf).replace(pat, rep20)

    # 2) UTF-16LE exact replacement
    old16 = "Made for iOSGods.com".encode('utf-16-le')
    if old16 in buf:
        rep16 = new_title[:20].ljust(20).encode('utf-16-le')
        hits += buf.count(old16)
        buf[:] = bytes(buf).replace(old16, rep16)

    # 3) Split string replacement
    if hits == 0:
        if b"iOSGods.com\x00" in buf or b"iosgods.com\x00" in buf:
            if b"Made for \x00" in buf and len(tb) > 11:
                p1 = tb[:9].ljust(9, b' ') + b'\x00'
                p2 = tb[9:20].ljust(11, b' ') + b'\x00'
                buf[:] = bytes(buf).replace(b"Made for \x00", p1)
                buf[:] = bytes(buf).replace(b"iOSGods.com\x00", p2).replace(b"iosgods.com\x00", p2)
            else:
                p2 = tb[:11].ljust(11, b' ') + b'\x00'
                buf[:] = bytes(buf).replace(b"Made for \x00", (b' ' * 9) + b'\x00')
                buf[:] = bytes(buf).replace(b"iOSGods.com\x00", p2).replace(b"iosgods.com\x00", p2)
            hits += 1

    return hits

def safe_patch_hex_colors(buf, body_hex_str, hdr_hex_str):
    c_hits = 0
    b_new = body_hex_str.encode('ascii')
    h_new = hdr_hex_str.encode('ascii')

    body_reds = [b"E72E2A", b"FF0000", b"E50914", b"FF3B30", b"D92B27", b"E74C3C", b"F1322E", b"EB332E"]
    hdr_reds  = [b"BD2522", b"C0392B", b"961E1B", b"B0231F", b"A8201D"]

    for hr in body_reds:
        for pat in (hr, hr.lower()):
            if pat in buf:
                c_hits += buf.count(pat)
                buf[:] = bytes(buf).replace(pat, b_new)

    for hr in hdr_reds:
        for pat in (hr, hr.lower()):
            if pat in buf:
                c_hits += buf.count(pat)
                buf[:] = bytes(buf).replace(pat, h_new)

    return c_hits

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

titles = icons = colors = 0
for p in files:
    rel = os.path.relpath(p, app)
    rel_low = rel.lower()
    is_main = (rel == main_exe)

    if any(sdk in rel_low for sdk in IGNORE_SDKS):
        continue

    with open(p, 'rb') as f:
        data = f.read()

    low = data.lower()
    # Target iGameGod framework or any binary containing menu markers
    is_menu_file = 'igamegod' in rel_low or p.endswith('.dylib') or b'iosgods' in low or b'modslider' in low

    if not is_menu_file and not is_main:
        continue

    new = bytearray(data)

    # 1) Patch Title
    t_hits = safe_patch_title(new, title)
    titles += t_hits

    # 2) Patch Red Colors -> Blue inside iGameGod / menu binaries
    c_hits = 0
    if 'igamegod' in rel_low or b'iosgods' in low or t_hits > 0:
        c_hits = safe_patch_hex_colors(new, hex_col, hdr_hex)
        colors += c_hits

    # 3) Patch Icons inside iGameGod / menu binary
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

    i_hits = 0
    if 'igamegod' in rel_low or b'modslider' in low or t_hits > 0:
        for m, orig, (w, h) in b64s:
            try:
                png = make_png(len(orig), w, h)
                if png is not None:
                    nb = base64.b64encode(png)
                    if len(nb) == len(m):
                        new = bytearray(bytes(new).replace(m, nb))
                        i_hits += 1
            except Exception:
                pass
        for s0, e0, w, h in raws:
            try:
                png = make_png(e0 - s0, w, h)
                if png is not None:
                    new[s0:e0] = png
                    i_hits += 1
            except Exception:
                pass
        icons += i_hits

    if bytes(new) != data:
        with open(p, 'wb') as f:
            f.write(bytes(new))
        print(f"  [Patched {rel}] titles: {t_hits}, icons: {i_hits}, hex-colors: {c_hits}", flush=True)

print(f"  Summary -> titles: {titles}, icons: {icons}, hex-color patches: {colors}")
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
    raw = f.read()
is_bin = raw.startswith(b'bplist')
d = plistlib.loads(raw)
d['CFBundleDisplayName'] = name
d['CFBundleName'] = name
with open(path, 'wb') as f:
    plistlib.dump(d, f, fmt=plistlib.FMT_BINARY if is_bin else plistlib.FMT_XML)
PY

  # 2) App icon
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

  # 3) Patch Mod Menu inside iGameGod framework
  python3 "$WORK/patch_menu.py" "$APP" "$MENU_TITLE" "$MENU_ICON" "$MENU_COLOR_HEX" "$WORK/debug"

  # 4) Replace menu icons inside iGameGod framework folder if any PNG exists
  if [ -d "$APP/Frameworks/iGameGod.framework" ]; then
    while IFS= read -r -d '' f; do
      read -r w h < <(python3 -c "
import struct, sys
b = open(sys.argv[1], 'rb').read(64)
i = b.find(b'IHDR')
if i >= 0:
    print(*struct.unpack('>II', b[i+4:i+12]))
else:
    print(0, 0)
" "$f")
      if [ "$w" -ge 24 ] && [ "$w" -le 512 ]; then
        resize "$MENU_ICON" "$w" "$h" "$f.new" && mv "$f.new" "$f"
        echo "  Replaced framework icon: $f (${w}x${h})"
      fi
    done < <(find "$APP/Frameworks/iGameGod.framework" -type f -iname "*.png" -print0)
  fi

  # 5) Re-pack cleanly without breaking entitlements
  (cd "$T" && zip -qry "$WORK/out/$fname" Payload)
done

echo "== Uploading to $TO_TAG"
gh release view "$TO_TAG" -R "$REPO" >/dev/null 2>&1 || \
  gh release create "$TO_TAG" -R "$REPO" -t "$TO_TAG" -n "Rebranded IPAs"
gh release upload "$TO_TAG" "$WORK"/out/*.ipa -R "$REPO" --clobber

rm -rf "$WORK/tmp"
echo "Done."
