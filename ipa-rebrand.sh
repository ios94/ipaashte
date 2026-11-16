#!/usr/bin/env bash
# ipa-rebrand.sh (Blue Menu + Deep Title Patcher + Anti-Crash)

set -euo pipefail

### ===== SETTINGS ====
REPO="${REPO:-USERNAME/REPO}"
FROM_TAG="${FROM_TAG:-V.1}"
TO_TAG="${TO_TAG:-V.5}"
NEW_NAME="${NEW_NAME:-My App}"
NEW_LOGO="${NEW_LOGO:-logo.png}"
MENU_TITLE="${MENU_TITLE:-Ashte Mod}"
MENU_ICON="${MENU_ICON:-menu_icon.png}"
MENU_COLOR_HEX="${MENU_COLOR_HEX:-1E64E8}" # Default nice Blue
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

# ---- Binary patcher: Menu Title + Menu Icon + Red-to-Blue Menu Color ----
cat > "$WORK/patch_menu.py" <<'PY'
import sys, os, re, io, base64, struct, zlib, plistlib, shutil
from PIL import Image

app, title, icon_path, hex_col = sys.argv[1:5]
debug_dir = sys.argv[5] if len(sys.argv) > 5 else ''

if not title.strip():
    title = "Ashte Mod"

hex_col = hex_col.lstrip('#').strip()
if len(hex_col) != 6:
    hex_col = "1E64E8"
BLUE_R = int(hex_col[0:2], 16)
BLUE_G = int(hex_col[2:4], 16)
BLUE_B = int(hex_col[4:6], 16)

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

def patch_title_everywhere(buf, new_title):
    """Finds and replaces 'Made for iOSGods.com' in plain, case-insensitive, split, XOR, and C-string forms."""
    hits = 0
    tb = new_title.encode('utf-8')

    # 1) Regex search for any "Made for ... iOSGods.com" up to null byte
    for m in list(re.finditer(rb'Made for [^\x00]{3,25}?iOSGods\.com', bytes(buf), re.I)):
        s, e = m.start(), m.end()
        length = e - s
        buf[s:e] = tb[:length].ljust(length, b' ')
        hits += 1

    # 2) Format string variations: "Made for %@" or "Made for %s"
    for m in list(re.finditer(rb'Made for %[@s][!]?', bytes(buf), re.I)):
        s, e = m.start(), m.end()
        length = e - s
        # Replace without keeping %@ so ObjC doesn't even read the argument, or pad safely
        buf[s:e] = tb[:length].ljust(length, b' ')
        hits += 1

    # 3) Split pieces ("Made for \x00" and "iOSGods.com\x00")
    if hits == 0:
        for m in list(re.finditer(rb'iOSGods\.com', bytes(buf), re.I)):
            s, e = m.start(), m.end()
            # Check if preceded by "Made for " nearby
            mf = bytes(buf).find(b"Made for \x00")
            if mf >= 0:
                p1 = tb[:9].ljust(9, b' ')
                p2 = tb[9:20].ljust(11, b' ')
                buf[mf:mf+9] = p1
                buf[s:e] = p2
            else:
                buf[s:e] = tb[:11].ljust(11, b' ')
            hits += 1

    # 4) Single-byte XOR obfuscation scan (commonly used in encrypted iOSGods dylibs)
    target_plain = b"Made for iOSGods.com"
    rep_plain = tb[:20].ljust(20, b' ')
    raw_bytes = bytes(buf)
    for key in range(1, 256):
        xored_target = bytes(b ^ key for b in target_plain)
        pos = raw_bytes.find(xored_target)
        if pos >= 0:
            xored_rep = bytes(b ^ key for b in rep_plain)
            buf[pos:pos+20] = xored_rep
            raw_bytes = bytes(buf)
            hits += 1

    return hits

def patch_red_to_blue(buf):
    """Patches Ted2 / iOSGods Mod Menu red colors into Blue inside the Mach-O binary."""
    c_hits = 0

    # A) Hex string colors inside binary (case-insensitive)
    hex_reds = [
        b"E72E2A", b"BD2522", b"FF0000", b"E50914", b"FF3B30",
        b"D92B27", b"C0392B", b"E74C3C", b"961E1B", b"B0231F"
    ]
    new_hex = f"{BLUE_R:02X}{BLUE_G:02X}{BLUE_B:02X}".encode('ascii')
    for hr in hex_reds:
        for pat in (hr, hr.lower()):
            if pat in buf:
                c_hits += buf.count(pat)
                buf[:] = bytes(buf).replace(pat, new_hex)

    # B) Objective-C UIColor selector: "redColor\x00" (8 chars + null) -> "cyanColor" or swap RGB floats
    # Note: "redColor" is 8 chars; "tanColor" or "blueColor" -> if "redColor\x00\x00" has padding, we can write "blueColor\x00"!
    idx = 0
    while True:
        pos = bytes(buf).find(b"redColor\x00", idx)
        if pos < 0:
            break
        if pos + 10 <= len(buf) and buf[pos+9] == 0:
            buf[pos:pos+10] = b"blueColor\x00"
            c_hits += 1
        idx = pos + 9

    # C) IEEE-754 Double & Float constants used by colorWithRed:green:blue:alpha:
    # In Ted2 Menu & Screenshot:
    #   Body Red   = RGB(231, 46, 42) or RGB(235, 51, 46) -> R/255 ~ 0.905..0.925, G/255 ~ 0.16..0.21, B/255 ~ 0.15..0.19
    #   Header Red = RGB(189, 37, 34) or RGB(194, 42, 38) -> R/255 ~ 0.741..0.765, G/255 ~ 0.14..0.17, B/255 ~ 0.13..0.16
    # Because R is high (~0.74 - 0.96) and B is low (~0.13 - 0.25), if we swap the R constant with a low value (0.12)
    # and the B constant with a high value (0.91), ANY red RGB call turns into a rich Blue!
    red_r_ints = [231, 232, 233, 234, 235, 189, 190, 191, 192, 193, 194, 220, 210, 200, 240, 250]
    red_g_ints = [46, 47, 48, 49, 50, 51, 52, 37, 38, 39, 40, 41, 42, 43]
    red_b_ints = [42, 43, 44, 45, 46, 34, 35, 36, 37, 38, 30, 32]

    # Replace exact Double (8-byte) & Float (4-byte) representations of X / 255.0 and X / 100.0
    # High Red -> Low Red (Blue R component: BLUE_R / 255.0)
    for r_val in red_r_ints:
        for denom in (255.0,):
            old_d = struct.pack('<d', r_val / denom)
            new_d = struct.pack('<d', BLUE_R / 255.0)
            if old_d in buf:
                c_hits += buf.count(old_d)
                buf[:] = bytes(buf).replace(old_d, new_d)
            old_f = struct.pack('<f', r_val / denom)
            new_f = struct.pack('<f', BLUE_R / 255.0)
            if old_f in buf:
                c_hits += buf.count(old_f)
                buf[:] = bytes(buf).replace(old_f, new_f)

    # Low Green -> Blue G component (BLUE_G / 255.0)
    for g_val in red_g_ints:
        old_d = struct.pack('<d', g_val / 255.0)
        new_d = struct.pack('<d', BLUE_G / 255.0)
        if old_d in buf:
            c_hits += buf.count(old_d)
            buf[:] = bytes(buf).replace(old_d, new_d)

    # Low Blue -> High Blue (BLUE_B / 255.0)
    for b_val in red_b_ints:
        old_d = struct.pack('<d', b_val / 255.0)
        new_d = struct.pack('<d', BLUE_B / 255.0)
        if old_d in buf:
            c_hits += buf.count(old_d)
            buf[:] = bytes(buf).replace(old_d, new_d)

    # Also check common decimal literals (e.g. 0.90, 0.91, 0.92, 0.89, 0.74, 0.75, 0.76 for R; 0.16, 0.17, 0.18, 0.14, 0.15 for B)
    for dec_r in (0.88, 0.89, 0.90, 0.91, 0.92, 0.93, 0.74, 0.75, 0.76, 0.77, 0.78):
        old_d = struct.pack('<d', dec_r)
        new_d = struct.pack('<d', 0.12)
        if old_d in buf:
            c_hits += buf.count(old_d)
            buf[:] = bytes(buf).replace(old_d, new_d)

    for dec_b in (0.13, 0.14, 0.15, 0.16, 0.17, 0.18, 0.19, 0.20):
        old_d = struct.pack('<d', dec_b)
        new_d = struct.pack('<d', 0.92)
        if old_d in buf:
            c_hits += buf.count(old_d)
            buf[:] = bytes(buf).replace(old_d, new_d)

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
    is_main = (rel == main_exe)
    with open(p, 'rb') as f:
        data = f.read()

    low = data.lower()
    if debug_dir and not is_main and len(data) < 60_000_000 and (
            p.endswith('.dylib') or b'gods' in low or b'multiplier' in low):
        os.makedirs(debug_dir, exist_ok=True)
        shutil.copy(p, os.path.join(debug_dir, rel.replace('/', '__')))

    new = bytearray(data)

    # 1) Patch Title
    t_hits = patch_title_everywhere(new, title)
    titles += t_hits

    # Identify if this Mach-O is the Mod Menu dylib
    is_menu_bin = (
        p.endswith('.dylib') or b'modslider' in low or b'iosgods' in low
        or b'multiplier' in low or t_hits > 0
    ) and b'igamegod' not in low and not is_main

    # 2) Patch Red Menu Colors -> Blue inside the Mod Menu dylib
    c_hits = 0
    if is_menu_bin:
        c_hits = patch_red_to_blue(new)
        colors += c_hits

    # 3) Patch Floating & Header Icons
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

    if (is_menu_bin or (is_main and icons == 0 and t_hits > 0)):
        for m, orig, (w, h) in b64s:
            try:
                png = make_png(len(orig), w, h)
                if png is not None:
                    nb = base64.b64encode(png)
                    if len(nb) == len(m):
                        new = bytearray(bytes(new).replace(m, nb))
                        icons += 1
            except Exception:
                pass
        for s0, e0, w, h in raws:
            try:
                png = make_png(e0 - s0, w, h)
                if png is not None:
                    new[s0:e0] = png
                    icons += 1
            except Exception:
                pass

    if bytes(new) != data:
        with open(p, 'wb') as f:
            f.write(bytes(new))
        print(f"  [Patched {rel}] titles: {t_hits}, icons: {icons}, blue-color patches: {c_hits}", flush=True)

print(f"  Summary -> titles: {titles}, icons: {icons}, color patches: {colors}")
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

  # 3) Mod menu: title + floating icon + Red-to-Blue color patch
  python3 "$WORK/patch_menu.py" "$APP" "$MENU_TITLE" "$MENU_ICON" "$MENU_COLOR_HEX" "$WORK/debug"

  # 4) Red -> Blue in any plain text resource files (.json, .css, .js, .html)
  for c in FF0000 E50914 FF3B30 E72E2A BD2522; do
    find "$APP" -type f \( -name "*.json" -o -name "*.css" -o -name "*.js" -o -name "*.html" \) \
      -exec perl -pi -e "s/#$c/#$MENU_COLOR_HEX/gi" {} +
  done

  # 5) Re-sign modified Mach-O binaries with ldid (prevents crash)
  if command -v ldid >/dev/null 2>&1; then
    echo "  Re-signing dylibs and app bundle with ldid..."
    find "$APP" -type f \( -name "*.dylib" -o -path "*/Frameworks/*.framework/*" \) -exec ldid -S {} + 2>/dev/null || true
    ldid -S "$APP" 2>/dev/null || true
  fi

  # 6) Re-pack
  (cd "$T" && zip -qry "$WORK/out/$fname" Payload)
done

echo "== Uploading to $TO_TAG"
gh release view "$TO_TAG" -R "$REPO" >/dev/null 2>&1 || \
  gh release create "$TO_TAG" -R "$REPO" -t "$TO_TAG" -n "Rebranded IPAs"
gh release upload "$TO_TAG" "$WORK"/out/*.ipa -R "$REPO" --clobber

rm -rf "$WORK/tmp"
echo "Done."
