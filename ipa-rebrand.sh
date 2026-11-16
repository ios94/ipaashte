#!/usr/bin/env bash
# ipa-rebrand.sh (100% Crash-Free Safe Edition)

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

# ---- Crash-Free Binary Patcher (ONLY touches verified strings & exact-size PNGs) ----
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

# Calculate a slightly darker 6-char hex for header bars
r = max(0, int(int(hex_col[0:2], 16) * 0.78))
g = max(0, int(int(hex_col[2:4], 16) * 0.78))
b = max(0, int(int(hex_col[4:6], 16) * 0.78))
hdr_hex = f"{r:02X}{g:02X}{b:02X}"

MACHO = (b'\xcf\xfa\xed\xfe', b'\xca\xfe\xba\xbe', b'\xbe\xba\xfe\xca')
B64 = re.compile(rb'iVBORw0KGgo[A-Za-z0-9+/]{120,}={0,2}')
PNG_SIG = b'\x89PNG\r\n\x1a\n'
PNG_END = b'IEND\xaeB`\x82'

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

def safe_patch_title(buf, new_title):
    """Strictly replaces exact-length ASCII/UTF-8 string literals without touching null terminators or %@."""
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

    # 3) If "Made for iOSGods.com" is split into "Made for " (9B) and "iOSGods.com" (11B)
    # Only replace when followed by null byte (\x00) so we NEVER corrupt URLs like "https://iosgods.com/..."
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
        elif b"Made for %@" in buf:
            # Keep "%@" intact if needed, or replace "Made for " (9 chars) with spaces and put title in "iOSGods.com"
            if b"iOSGods.com" in buf:
                p1 = tb[:9].ljust(9, b' ')
                p2 = tb[9:20].ljust(11, b' ')
                buf[:] = bytes(buf).replace(b"Made for %@", p1 + b"%@")
                buf[:] = bytes(buf).replace(b"iOSGods.com", p2)
                hits += 1

    return hits

def safe_patch_hex_colors(buf, body_hex_str, hdr_hex_str):
    """Safely replaces ONLY 6-byte ASCII hex color strings (never touches binary float/ARM64 instructions!)."""
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

    # Never touch Ad/Analytics SDKs or iGameGod's own cheat engine framework!
    if any(sdk in rel_low for sdk in IGNORE_SDKS) or 'igamegod' in rel_low:
        continue

    with open(p, 'rb') as f:
        data = f.read()

    low = data.lower()
    has_menu = (
        p.endswith('.dylib') or b'modslider' in low
        or b'made for iosgods' in low or b'damage multiplier' in low
    )
    if not has_menu and not is_main:
        continue

    # Save untouched dylibs & scan main executable strings for debugging
    if debug_dir:
        os.makedirs(debug_dir, exist_ok=True)
        if not is_main and len(data) < 60_000_000:
            shutil.copy(p, os.path.join(debug_dir, rel.replace('/', '__')))
        # Extract any strings near "Multiplier" or "Made for" so we can see exact bytes
        matches = re.findall(rb'[\x20-\x7e]{4,60}(?:Multiplier|Made for|iOSGods|E72E2A|BD2522)[\x20-\x7e]{0,40}', data, re.I)
        if matches:
            with open(os.path.join(debug_dir, 'menu_strings_found.txt'), 'a') as sf:
                sf.write(f"=== {rel} ===\n")
                for m in matches[:50]:
                    sf.write("  " + m.decode('ascii', 'replace') + "\n")

    new = bytearray(data)

    # 1) Safe Title Patch
    t_hits = safe_patch_title(new, title)
    titles += t_hits

    # 2) Safe Hex Color Patch
    c_hits = safe_patch_hex_colors(new, hex_col, hdr_hex)
    colors += c_hits

    # 3) Safe Icon Patch (only inside the mod menu dylib, or main_exe if no dylib had icons)
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
    if (b'modslider' in low or p.endswith('.dylib') or t_hits > 0) and not (is_main and icons > 0):
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

  # List all dylibs and frameworks in the log so we can see where the menu lives
  echo "  Files inside app bundle:"
  find "$APP" -maxdepth 3 \( -name "*.dylib" -o -name "*.framework" \) | sed "s|$APP/|    |"

  # 1) App name (preserves exact Info.plist format)
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

  # 3) Safe Mod Menu Patch
  python3 "$WORK/patch_menu.py" "$APP" "$MENU_TITLE" "$MENU_ICON" "$MENU_COLOR_HEX" "$WORK/debug"

  # 4) Red -> Blue in plain text files only
  for c in FF0000 E50914 FF3B30 E72E2A BD2522; do
    find "$APP" -type f \( -name "*.json" -o -name "*.css" -o -name "*.js" -o -name "*.html" \) \
      -exec perl -pi -e "s/#$c/#$MENU_COLOR_HEX/gi" {} +
  done

  # 5) Re-pack cleanly (without running ldid so original entitlements stay intact)
  (cd "$T" && zip -qry "$WORK/out/$fname" Payload)
done

echo "== Uploading to $TO_TAG"
gh release view "$TO_TAG" -R "$REPO" >/dev/null 2>&1 || \
  gh release create "$TO_TAG" -R "$REPO" -t "$TO_TAG" -n "Rebranded IPAs"
gh release upload "$TO_TAG" "$WORK"/out/*.ipa -R "$REPO" --clobber

rm -rf "$WORK/tmp"
echo "Done."
