#!/usr/bin/env bash
# ipa-rebrand.sh (Runtime UI Hook Edition - Overrides Encrypted iOSGods Menu in RAM)

set -euo pipefail

REPO="${REPO:-USERNAME/REPO}"
FROM_TAG="${FROM_TAG:-V.1}"
TO_TAG="${TO_TAG:-V.5}"
NEW_NAME="${NEW_NAME:-My App}"
NEW_LOGO="${NEW_LOGO:-logo.png}"
MENU_TITLE="${MENU_TITLE:-Ashte Mod}"
MENU_ICON="${MENU_ICON:-menu_icon.png}"
MENU_COLOR_HEX="${MENU_COLOR_HEX:-1E64E8}"

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

# Convert HEX to RGB floats (0.0 - 1.0)
read -r R_FLT G_FLT B_FLT HR_FLT HG_FLT HB_FLT < <(python3 - "$MENU_COLOR_HEX" <<'PY'
import sys
h = sys.argv[1].lstrip('#').strip()
if len(h) != 6: h = "1E64E8"
r, g, b = int(h[0:2], 16)/255.0, int(h[2:4], 16)/255.0, int(h[4:6], 16)/255.0
print(f"{r:.4f} {g:.4f} {b:.4f} {r*0.75:.4f} {g*0.75:.4f} {b*0.75:.4f}")
PY
)

# 1) Build the Runtime Objective-C Hook Dylib (libashte.dylib)
cat > "$WORK/ashte_hook.m" <<EOF
#import <UIKit/UIKit.h>
#import <objc/runtime.h>

static NSString *const kNewTitle = @"${MENU_TITLE}";

static BOOL isMenuRed(UIColor *color, BOOL *isDarkHeader) {
    if (!color) return NO;
    CGFloat r = 0, g = 0, b = 0, a = 0;
    if ([color getRed:&r green:&g blue:&b alpha:&a]) {
        // Detects Ted2 / iOSGods red shades (high red > 0.65, low green < 0.30, low blue < 0.30)
        if (r > 0.65 && g < 0.30 && b < 0.30 && a > 0.5) {
            if (isDarkHeader) *isDarkHeader = (r < 0.82);
            return YES;
        }
    }
    return NO;
}

static void scrubViewHierarchy(UIView *view) {
    if (!view) return;

    // 1. Change any Red menu background to Blue
    BOOL isHeader = NO;
    if (isMenuRed(view.backgroundColor, &isHeader)) {
        CGFloat alpha = CGColorGetAlpha(view.backgroundColor.CGColor);
        if (isHeader) {
            view.backgroundColor = [UIColor colorWithRed:${HR_FLT} green:${HG_FLT} blue:${HB_FLT} alpha:alpha];
        } else {
            view.backgroundColor = [UIColor colorWithRed:${R_FLT} green:${G_FLT} blue:${B_FLT} alpha:alpha];
        }
    }

    // 2. Change UISlider red tint colors to Blue
    if ([view isKindOfClass:[UISlider class]]) {
        UISlider *slider = (UISlider *)view;
        if (isMenuRed(slider.minimumTrackTintColor, NULL)) {
            slider.minimumTrackTintColor = [UIColor colorWithRed:${HR_FLT} green:${HG_FLT} blue:${HB_FLT} alpha:1.0];
        }
        if (isMenuRed(slider.thumbTintColor, NULL)) {
            slider.thumbTintColor = [UIColor colorWithRed:${R_FLT} green:${G_FLT} blue:${B_FLT} alpha:1.0];
        }
    }

    // 3. Change "Made for iOSGods.com" label text to custom title
    if ([view isKindOfClass:[UILabel class]]) {
        UILabel *lbl = (UILabel *)view;
        NSString *txt = lbl.text;
        if (txt && ([txt rangeOfString:@"iOSGods" options:NSCaseInsensitiveSearch].location != NSNotFound ||
                    [txt rangeOfString:@"Made for" options:NSCaseInsensitiveSearch].location != NSNotFound)) {
            lbl.text = kNewTitle;
        }
    }

    // 4. Replace small menu header/floating icon with custom menu_icon.png
    if ([view isKindOfClass:[UIImageView class]] && view.tag != 994411) {
        CGSize sz = view.bounds.size;
        // Menu header icon & floating button are between 25x25 and 85x85 inside the menu/window
        if (sz.width >= 24 && sz.width <= 90 && fabs(sz.width - sz.height) <= 12) {
            UIView *p = view.superview;
            BOOL insideMenu = NO;
            while (p) {
                if (isMenuRed(p.backgroundColor, NULL) || p.backgroundColor != nil) {
                    insideMenu = YES;
                    break;
                }
                p = p.superview;
            }
            if (insideMenu) {
                NSString *iconPath = [[NSBundle mainBundle] pathForResource:@"ashte_menu_icon" ofType:@"png"];
                if (iconPath) {
                    UIImage *customImg = [UIImage imageWithContentsOfFile:iconPath];
                    if (customImg && view.bounds.size.width > 30) {
                        ((UIImageView *)view).image = customImg;
                        view.tag = 994411;
                    }
                }
            }
        }
    }

    for (UIView *sub in view.subviews) {
        scrubViewHierarchy(sub);
    }
}

__attribute__((constructor))
static void initAshteHook(void) {
    dispatch_async(dispatch_get_main_queue(), ^{
        [NSTimer scheduledTimerWithTimeInterval:0.15 repeats:YES block:^(NSTimer * _Nonnull timer) {
            for (UIWindow *win in [UIApplication sharedApplication].windows) {
                scrubViewHierarchy(win);
            }
        }];
    });
}
EOF

echo "== Compiling iOS ARM64 Runtime Hook (libashte.dylib)"
SDK_PATH="$(xcrun --sdk iphoneos --show-sdk-path)"
xcrun --sdk iphoneos clang -arch arm64 -dynamiclib \
  -isysroot "$SDK_PATH" \
  -miphoneos-version-min=12.0 \
  -framework UIKit -framework Foundation -framework CoreGraphics \
  -install_name "@rpath/libashte.dylib" \
  "$WORK/ashte_hook.m" -o "$WORK/libashte.dylib"

echo "== Downloading IPAs from $FROM_TAG"
gh release download "$FROM_TAG" -R "$REPO" -p "*.ipa" -D "$WORK/in"

for ipa in "$WORK"/in/*.ipa; do
  fname="$(basename "$ipa")"
  echo "== Processing $fname"
  T="$WORK/tmp"; rm -rf "$T"; mkdir "$T"
  unzip -q "$ipa" -d "$T"
  APP="$(ls -d "$T"/Payload/*.app | head -n1)"

  # 1) Update App Name in Info.plist
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

  # 2) Replace App Icons
  while IFS= read -r -d '' f; do
    read -r w h < <(python3 -c "
import struct, sys
b = open(sys.argv[1], 'rb').read(64)
i = b.find(b'IHDR')
print(*(struct.unpack('>II', b[i+4:i+12]) if i >= 0 else (180, 180)))
" "$f")
    resize "$NEW_LOGO" "$w" "$h" "$f.new" && mv "$f.new" "$f"
  done < <(find "$APP" -maxdepth 1 -type f \( -iname "AppIcon*.png" -o -iname "Icon*.png" \) -print0)

  # 3) Copy custom menu icon & libashte.dylib into Frameworks
  mkdir -p "$APP/Frameworks"
  cp "$WORK/libashte.dylib" "$APP/Frameworks/libashte.dylib"
  resize "$MENU_ICON" 120 120 "$APP/ashte_menu_icon.png"

  # 4) Inject Load Command into libcatscrasharenaturbostars.dylib (or main executable) using LIEF
  python3 - "$APP" <<'PY'
import os, sys, plistlib, lief

app = sys.argv[1]
target_bin = None

# Prefer hooking onto the existing mod menu dylib so we don't even touch the main executable!
for root, _, names in os.walk(os.path.join(app, "Frameworks")):
    for n in names:
        if n.endswith(".dylib") and n != "libashte.dylib":
            target_bin = os.path.join(root, n)
            break

if not target_bin:
    with open(os.path.join(app, "Info.plist"), "rb") as f:
        exe = plistlib.load(f).get("CFBundleExecutable", "")
    target_bin = os.path.join(app, exe)

print(f"  Injecting @rpath/libashte.dylib into {os.path.relpath(target_bin, app)}")
binary = lief.parse(target_bin)
binary.add_library("@rpath/libashte.dylib")
binary.write(target_bin)
PY

  # 5) Re-pack IPA
  (cd "$T" && zip -qry "$WORK/out/$fname" Payload)
done

echo "== Uploading to $TO_TAG"
gh release view "$TO_TAG" -R "$REPO" >/dev/null 2>&1 || \
  gh release create "$TO_TAG" -R "$REPO" -t "$TO_TAG" -n "Rebranded IPAs"
gh release upload "$TO_TAG" "$WORK"/out/*.ipa -R "$REPO" --clobber

rm -rf "$WORK/tmp"
echo "Done."
