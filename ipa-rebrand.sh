#!/usr/bin/env bash
# ipa-rebrand.sh (Full Obfuscated Title + Blue Menu + Icon Patcher)

set -euo pipefail

### ===== SETTINGS ====
REPO="${REPO:-USERNAME/REPO}"
FROM_TAG="${FROM_TAG:-V.1}"
TO_TAG="${TO_TAG:-V.5}"
NEW_NAME="${NEW_NAME:-My App}"
NEW_LOGO="${NEW_LOGO:-logo.png}"
MENU_TITLE="${MENU_TITLE:-Ashte Mod}"
MENU_ICON="${MENU_ICON:-menu_icon.png}"
MENU_COLOR_HEX="${MENU_COLOR_HEX:-1E64E8}" # Blue HEX
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

BLUE_R = int(hex_col[0:2], 16)
BLUE_G = int(hex_col[2:4], 16)
BLUE_B = int(hex_col[4:6], 16)

HDR_R = max(0, int(BLUE_R * 0.78))
HDR_G = max(0, int(BLUE_G * 0.78))
HDR_B = max(0, int(BLUE_B * 0.78))

MACHO = (b'\xcf\xfa\xed\xfe', b'\xca\xfe\xba\xbe', b'\xbe\xba\xfe\xca')
B64 = re.compile(rb'iVBORw0KGgo[A-Za-z0-9+/]{80,}={0,2}')
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
    if 16 <= w <= 700 and 16 <= h <= 700 and 200 <= len(blob) <= 500000:
        return w, h
    return None

def looks_like_icon(blob):
    try:
        im = Image.open(io.BytesIO(blob)).convert('RGBA')
    except Exception:
        return True
    total = im.width * im.height
    opaque = sum(im.getchannel('A').histogram()[100:])
    colors = im.convert('RGB').getcolors(maxcolors=1 << 24) or []
    return opaque >= 0.15 * total and len(colors) >= 15

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

def deep_patch_title(buf, new_title):
    """Finds 'Made for iOSGods.com' in plain, split, UTF-16, Base64, and XOR-encrypted forms."""
    hits = 0
    tb = new_title.encode('utf-8')
    rep20 = tb[:20].ljust(20, b' ')

    # 1) Plain & case-insensitive
    for m in list(re.finditer(rb'Made for [^\x00]{0,25}?iOSGods\.com', bytes(buf), re.I)):
        s, e = m.start(), m.end()
        buf[s:e] = tb[:e-s].ljust(e-s, b' ')
        hits += 1

    # 2) Split ("Made for " + "iOSGods.com")
    for m in list(re.finditer(rb'iOSGods\.com', bytes(buf), re.I)):
        s, e = m.start(), m.end()
        # Skip URLs like https://iosgods.com
        if s >= 3 and bytes(buf[s-3:s]) == b'://':
            continue
        buf[s:e] = tb[:e-s].ljust(e-s, b' ')
        hits += 1
    if hits > 0 and b"Made for " in buf:
        buf[:] = bytes(buf).replace(b"Made for ", b" " * 9)

    # 3) UTF-16LE
    old16 = "Made for iOSGods.com".encode('utf-16-le')
    if old16 in buf:
        rep16 = new_title[:20].ljust(20).encode('utf-16-le')
        hits += buf.count(old16)
        buf[:] = bytes(buf).replace(old16, rep16)

    # 4) Base64 encoded
    b64_old = base64.b64encode(b"Made for iOSGods.com")
    if b64_old in buf:
        b64_new = base64.b64encode(rep20)
        if len(b64_new) == len(b64_old):
            buf[:] = bytes(buf).replace(b64_old, b64_new)
            hits += 1

    # 5) Single-byte XOR obfuscation (key 1..255)
    raw = bytes(buf)
    for target_str in (b"Made for iOSGods.com", b"iOSGods.com"):
        rep_str = tb[:len(target_str)].ljust(len(target_str), b' ')
        for key in range(1, 256):
            x_target = bytes(b ^ key for b in target_str)
            pos = 0
            while True:
                idx = raw.find(x_target, pos)
                if idx < 0:
                    break
                x_rep = bytes(b ^ key for b in rep_str)
                buf[idx:idx+len(target_str)] = x_rep
                raw = bytes(buf)
                hits += 1
                pos = idx + len(target_str)

    # 6) Rolling/Incremental XOR obfuscation (key + index)
    raw = bytes(buf)
    target_str = b"Made for iOSGods.com"
    for key in range(1, 256):
        x_target = bytes((b ^ ((key + i) & 0xFF)) for i, b in enumerate(target_str))
        idx = raw.find(x_target)
        if idx >= 0:
            x_rep = bytes((b ^ ((key + i) & 0xFF)) for i, b in enumerate(rep20))
            buf[idx:idx+20] = x_rep
            raw = bytes(buf)
            hits += 1

    return hits

def patch_menu_blue(buf):
    """Safely turns Ted2/iOSGods red menu into Blue inside the menu binary ONLY."""
    c_hits = 0
    b_new = f"{BLUE_R:02X}{BLUE_G:02X}{BLUE_B:02X}".encode('ascii')
    h_new = f"{HDR_R:02X}{HDR_G:02X}{HDR_B:02X}".encode('ascii')

    # 1) Hex strings
    for hr in [b"E72E2A", b"FF0000", b"E50914", b"FF3B30", b"D92B27", b"E74C3C", b"F1322E", b"EB332E"]:
        for pat in (hr, hr.lower()):
            if pat in buf:
                c_hits += buf.count(pat)
                buf[:] = bytes(buf).replace(pat, b_new)
    for hr in [b"BD2522", b"C0392B", b"961E1B", b"B0231F", b"A8201D"]:
        for pat in (hr, hr.lower()):
            if pat in buf:
                c_hits += buf.count(pat)
                buf[:] = bytes(buf).replace(pat, h_new)

    # 2) Double & Float RGB values used ONLY inside iGameGod/menu dylib (safe because we skip main game exe!)
    for r_val in (231, 232, 235, 189, 190, 194):
        for fmt in ('<d', '<f'):
            old_b = struct.pack(fmt, r_val / 255.0)
            if old_b in buf:
                tr = HDR_R if r_val < 205 else BLUE_R
                new_b = struct.pack(fmt, tr / 255.0)
                c_hits += buf.count(old_b)
                buf[:] = bytes(buf).replace(old_b, new_b)

    for g_val in (46, 48, 51, 37, 38, 42):
        for fmt in ('<d', '<f'):
            old_b = struct.pack(fmt, g_val / 255.0)
            if old_b in buf:
                tg = HDR_G if g_val < 42 else BLUE_G
                new_b = struct.pack(fmt, tg / 255.0)
                c_hits += buf.count(old_b)
                buf[:] = bytes(buf).replace(old_b, new_b)

    for b_val in (42, 44, 46, 34, 35, 38):
        for fmt in ('<d', '<f'):
            old_b = struct.pack(fmt, b_val / 255.0)
            if old_b in buf:
                tb = HDR_B if b_val < 38 else BLUE_B
                new_b = struct.pack(fmt, tb / 255.0)
                c_hits += buf.count(old_b)
                buf[:] = bytes(buf).replace(old_b, new_b)

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
    is_menu_bin = 'igamegod' in rel_low or p.endswith('.dylib') or b'iosgods' in low or b'modslider' in low

    if not is_menu_bin and not is_main:
        continue

    new = bytearray(data)

    # 1) Deep Title Patch (Plain + Split + Base64 + XOR)
    t_hits = deep_patch_title(new, title)
    titles += t_hits

    # 2) Blue Color Patch (ONLY on non-main menu dylibs/iGameGod so main exe never crashes!)
    c_hits = 0
    if not is_main and (is_menu_bin or t_hits > 0):
        c_hits = patch_menu_blue(new)
        colors += c_hits

    # 3) Icon Patch (Base64 & Raw PNG)
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
    if not is_main or (icons == 0 and t_hits > 0):
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
        print(f"  [Patched {rel}] titles: {t_hits}, icons: {i_hits}, blue-colors: {c_hits}", flush=True)

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

  # 3) Deep Patch Mod Menu (Title + Icon + Blue Color)
  python3 "$WORK/patch_menu.py" "$APP" "$MENU_TITLE" "$MENU_ICON" "$MENU_COLOR_HEX" "$WORK/debug"

  # 4) Re-pack cleanly
  (cd "$T" && zip -qry "$WORK/out/$fname" Payload)
done

echo "== Uploading to $TO_TAG"
gh release view "$TO_TAG" -R "$REPO" >/dev/null 2>&1 || \
  gh release create "$TO_TAG" -R "$REPO" -t "$TO_TAG" -n "Rebranded IPAs"
gh release upload "$TO_TAG" "$WORK"/out/*.ipa -R "$REPO" --clobber

rm -rf "$WORK/tmp"
echo "Done."
