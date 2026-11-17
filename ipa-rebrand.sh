#!/usr/bin/env bash
# ipa-rebrand.sh (Clean Syntax - Blue Menu + Custom Logo + Telegram Only Popup)

set -euo pipefail

REPO="${REPO:-USERNAME/REPO}"
FROM_TAG="${FROM_TAG:-V.1}"
TO_TAG="${TO_TAG:-V.5}"
NEW_NAME="${NEW_NAME:-My App}"
NEW_LOGO="${NEW_LOGO:-logo.png}"
MENU_TITLE="${MENU_TITLE:-Ashte Mod}"
MENU_ICON="${MENU_ICON:-menu_icon.png}"
MENU_COLOR_HEX="${MENU_COLOR_HEX:-1E64E8}"
TELEGRAM_URL="${TELEGRAM_URL:-https://t.me/ashtemobile}"

if [[ ! -f "$NEW_LOGO" ]]; then
  echo "Logo not found: $NEW_LOGO"
  exit 1
fi

if [[ ! -f "$MENU_ICON" ]]; then
  MENU_ICON="$NEW_LOGO"
fi

resize() {
  python3 - "$1" "$2" "$3" "$4" <<'PYR'
import sys
from PIL import Image
src, w, h, dst = sys.argv[1], int(sys.argv[2]), int(sys.argv[3]), sys.argv[4]
Image.open(src).convert("RGBA").resize((w, h), Image.LANCZOS).save(dst, "PNG")
PYR
}

WORK="$(pwd)/work"
rm -rf "$WORK"
mkdir -p "$WORK/in" "$WORK/out"

# Convert HEX to RGB floats (0.0 - 1.0)
read -r R_FLT G_FLT B_FLT HR_FLT HG_FLT HB_FLT < <(python3 - "$MENU_COLOR_HEX" <<'PY'
import sys
h = sys.argv[1].lstrip('#').strip()
if len(h) != 6:
    h = "1E64E8"
r, g, b = int(h[0:2], 16)/255.0, int(h[2:4], 16)/255.0, int(h[4:6], 16)/255.0
print(f"{r:.4f} {g:.4f} {b:.4f} {r*0.75:.4f} {g*0.75:.4f} {b*0.75:.4f}")
PY
)

# 1) Build the Runtime Objective-C Hook Dylib (libashte.dylib)
cat > "$WORK/ashte_hook.m" <<EOF
#import <UIKit/UIKit.h>
#import <objc/runtime.h>

static NSString *const kNewTitle = @"${MENU_TITLE}";
static NSString *const kTelegramURL = @"${TELEGRAM_URL}";

static UIImage *getCustomMenuIcon(void) {
    static UIImage *cachedIcon = nil;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        NSString *p = [[NSBundle mainBundle] pathForResource:@"ashte_menu_icon" ofType:@"png"];
        if (p) cachedIcon = [UIImage imageWithContentsOfFile:p];
    });
    return cachedIcon;
}

static BOOL isMenuRed(UIColor *color, BOOL *isDarkHeader) {
    if (!color) return NO;
    CGFloat r = 0, g = 0, b = 0, a = 0;
    if ([color getRed:&r green:&g blue:&b alpha:&a]) {
        if (r > 0.60 && g < 0.38 && b < 0.38 && a > 0.2) {
            if (isDarkHeader) *isDarkHeader = (r < 0.82);
            return YES;
        }
    }
    return NO;
}

static void openTelegramChannel(void) {
    NSURL *url = [NSURL URLWithString:kTelegramURL];
    if (!url) return;
    dispatch_async(dispatch_get_main_queue(), ^{
        UIApplication *app = [UIApplication sharedApplication];
        if ([app respondsToSelector:@selector(openURL:options:completionHandler:)]) {
            [app openURL:url options:@{} completionHandler:nil];
        } else {
#pragma clang diagnostic push
#pragma clang diagnostic ignored "-Wdeprecated-declarations"
            [app openURL:url];
#pragma clang diagnostic pop
        }
    });
}

// Redirect any external social/mod URL to Telegram
static void (*orig_openURL_opts)(id, SEL, NSURL *, NSDictionary *, void (^)(BOOL)) = NULL;
static void hooked_openURL_opts(id self, SEL _cmd, NSURL *url, NSDictionary *options, void (^completion)(BOOL)) {
    NSString *s = url.absoluteString.lowercaseString ?: @"";
    if ([s containsString:@"iosgods"] || [s containsString:@"twitter"] || [s containsString:@"x.com"] || [s containsString:@"facebook"] || [s containsString:@"youtube"]) {
        url = [NSURL URLWithString:kTelegramURL];
    }
    orig_openURL_opts(self, _cmd, url, options, completion);
}

static BOOL (*orig_openURL)(id, SEL, NSURL *) = NULL;
static BOOL hooked_openURL(id self, SEL _cmd, NSURL *url) {
    NSString *s = url.absoluteString.lowercaseString ?: @"";
    if ([s containsString:@"iosgods"] || [s containsString:@"twitter"] || [s containsString:@"x.com"] || [s containsString:@"facebook"] || [s containsString:@"youtube"]) {
        url = [NSURL URLWithString:kTelegramURL];
    }
    return orig_openURL(self, _cmd, url);
}

// Intercept UIAlertController popup and show ONLY "Telegram" + "Dismiss"
static void (*orig_presentVC)(id, SEL, UIViewController *, BOOL, void (^)(void)) = NULL;
static void hooked_presentVC(id self, SEL _cmd, UIViewController *vcToPresent, BOOL flag, void (^completion)(void)) {
    if ([vcToPresent isKindOfClass:[UIAlertController class]]) {
        UIAlertController *alert = (UIAlertController *)vcToPresent;
        BOOL isModPopup = NO;
        NSString *t = alert.title ?: @"";
        NSString *m = alert.message ?: @"";
        if ([t rangeOfString:@"iOSGods" options:NSCaseInsensitiveSearch].location != NSNotFound ||
            [t rangeOfString:kNewTitle options:NSCaseInsensitiveSearch].location != NSNotFound ||
            [m rangeOfString:@"iOSGods" options:NSCaseInsensitiveSearch].location != NSNotFound) {
            isModPopup = YES;
        }
        for (UIAlertAction *act in alert.actions) {
            NSString *at = act.title ?: @"";
            if ([at rangeOfString:@"Twitter" options:NSCaseInsensitiveSearch].location != NSNotFound ||
                [at rangeOfString:@"iOSGods" options:NSCaseInsensitiveSearch].location != NSNotFound ||
                [at rangeOfString:@"Credit" options:NSCaseInsensitiveSearch].location != NSNotFound ||
                [at rangeOfString:kNewTitle options:NSCaseInsensitiveSearch].location != NSNotFound) {
                isModPopup = YES;
                break;
            }
        }
        if (isModPopup && vcToPresent.view.tag != 887766) {
            UIAlertController *cleanAlert = [UIAlertController alertControllerWithTitle:kNewTitle
                                                                                message:nil
                                                                         preferredStyle:UIAlertControllerStyleAlert];
            cleanAlert.view.tag = 887766;
            [cleanAlert addAction:[UIAlertAction actionWithTitle:@"Telegram"
                                                           style:UIAlertActionStyleDefault
                                                         handler:^(UIAlertAction * _Nonnull action) {
                openTelegramChannel();
            }]];
            [cleanAlert addAction:[UIAlertAction actionWithTitle:@"Dismiss"
                                                           style:UIAlertActionStyleCancel
                                                         handler:nil]];
            orig_presentVC(self, _cmd, cleanAlert, flag, completion);
            return;
        }
    }
    orig_presentVC(self, _cmd, vcToPresent, flag, completion);
}

static void scrubViewHierarchy(UIView *view) {
    if (!view) return;

    // 1. Change Red menu background & slider tracks to Blue
    BOOL isHeader = NO;
    if (isMenuRed(view.backgroundColor, &isHeader)) {
        CGFloat alpha = CGColorGetAlpha(view.backgroundColor.CGColor);
        if (isHeader) {
            view.backgroundColor = [UIColor colorWithRed:${HR_FLT} green:${HG_FLT} blue:${HB_FLT} alpha:alpha];
        } else {
            view.backgroundColor = [UIColor colorWithRed:${R_FLT} green:${G_FLT} blue:${B_FLT} alpha:alpha];
        }
    }
    if (view.layer.borderColor && isMenuRed([UIColor colorWithCGColor:view.layer.borderColor], NULL)) {
        view.layer.borderColor = [UIColor colorWithRed:${R_FLT} green:${G_FLT} blue:${B_FLT} alpha:1.0].CGColor;
    }

    // 2. Change UISlider red tint & thumb to Blue
    if ([view isKindOfClass:[UISlider class]]) {
        UISlider *slider = (UISlider *)view;
        slider.minimumTrackTintColor = [UIColor colorWithRed:${HR_FLT} green:${HG_FLT} blue:${HB_FLT} alpha:1.0];
        slider.thumbTintColor = [UIColor colorWithRed:${R_FLT} green:${G_FLT} blue:${B_FLT} alpha:1.0];
    }

    // 3. Change Labels ("Made for iOSGods.com" -> Ashte Mod)
    if ([view isKindOfClass:[UILabel class]]) {
        UILabel *lbl = (UILabel *)view;
        NSString *txt = lbl.text;
        if (txt) {
            if ([txt rangeOfString:@"Twitter" options:NSCaseInsensitiveSearch].location != NSNotFound) {
                lbl.text = @"Telegram";
            } else if ([txt rangeOfString:@"iOSGods" options:NSCaseInsensitiveSearch].location != NSNotFound ||
                       [txt rangeOfString:@"Made for" options:NSCaseInsensitiveSearch].location != NSNotFound) {
                lbl.text = kNewTitle;
            }
        }
    }

    // 4. Replace skull/mascot icon in menu header & floating button with custom logo
    UIImage *customImg = getCustomMenuIcon();
    if (customImg && view.tag != 994411) {
        CGSize sz = view.bounds.size;
        if (sz.width >= 20 && sz.width <= 95 && sz.height >= 20 && sz.height <= 95 && fabs(sz.width - sz.height) <= 15) {
            if ([view isKindOfClass:[UIImageView class]]) {
                UIImageView *iv = (UIImageView *)view;
                if (iv.image && iv.frame.origin.x < 120) {
                    iv.image = customImg;
                    view.tag = 994411;
                }
            } else if ([view isKindOfClass:[UIButton class]]) {
                UIButton *btn = (UIButton *)view;
                if (btn.frame.origin.x < 120 && ([btn imageForState:UIControlStateNormal] || [btn backgroundImageForState:UIControlStateNormal])) {
                    if ([btn imageForState:UIControlStateNormal]) {
                        [btn setImage:customImg forState:UIControlStateNormal];
                    }
                    if ([btn backgroundImageForState:UIControlStateNormal]) {
                        [btn setBackgroundImage:customImg forState:UIControlStateNormal];
                    }
                    view.tag = 994411;
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
    Method mPres = class_getInstanceMethod([UIViewController class], @selector(presentViewController:animated:completion:));
    if (mPres) {
        orig_presentVC = (void *)method_getImplementation(mPres);
        method_setImplementation(mPres, (IMP)hooked_presentVC);
    }

    Method mOpenOpts = class_getInstanceMethod([UIApplication class], @selector(openURL:options:completionHandler:));
    if (mOpenOpts) {
        orig_openURL_opts = (void *)method_getImplementation(mOpenOpts);
        method_setImplementation(mOpenOpts, (IMP)hooked_openURL_opts);
    }
    Method mOpen = class_getInstanceMethod([UIApplication class], @selector(openURL:));
    if (mOpen) {
        orig_openURL = (void *)method_getImplementation(mOpen);
        method_setImplementation(mOpen, (IMP)hooked_openURL);
    }

    dispatch_async(dispatch_get_main_queue(), ^{
        [NSTimer scheduledTimerWithTimeInterval:0.12 repeats:YES block:^(NSTimer * _Nonnull timer) {
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
  -framework QuartzCore \
  -install_name "@rpath/libashte.dylib" \
  "$WORK/ashte_hook.m" -o "$WORK/libashte.dylib"

echo "== Downloading IPAs from $FROM_TAG"
gh release download "$FROM_TAG" -R "$REPO" -p "*.ipa" -D "$WORK/in"

for ipa in "$WORK"/in/*.ipa; do
  fname="$(basename "$ipa")"
  echo "== Processing $fname"
  T="$WORK/tmp"
  rm -rf "$T"
  mkdir -p "$T"
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

  # 3) Patch embedded base64 icons inside mod menu dylib
  python3 - "$APP" "$MENU_ICON" <<'PY'
import sys, os, re, io, base64, struct, zlib
from PIL import Image

app, icon_path = sys.argv[1:3]
B64 = re.compile(rb'iVBORw0KGgo[A-Za-z0-9+/]{80,}={0,2}')

def chunk(t, d):
    return struct.pack('>I', len(d)) + t + d + struct.pack('>I', zlib.crc32(t + d) & 0xffffffff)

def png_size(blob):
    i = blob.find(b'IHDR')
    if i < 0 or len(blob) < i + 12:
        return None
    w, h = struct.unpack('>II', blob[i+4:i+12])
    return (w, h) if (16 <= w <= 700 and 16 <= h <= 700) else None

def looks_like_mascot(blob):
    try:
        im = Image.open(io.BytesIO(blob)).convert('RGBA')
    except Exception:
        return False
    colors = im.convert('RGB').getcolors(maxcolors=1 << 24) or []
    return len(colors) >= 15

def make_png(target, w, h):
    src = Image.open(icon_path).convert('RGBA')
    s = 1.0
    while True:
        nw, nh = max(16, int(w * s)), max(16, int(h * s))
        small = src.resize((nw, nh), Image.LANCZOS)
        for im in (small, small.quantize(colors=128, method=Image.FASTOCTREE)):
            buf = io.BytesIO()
            im.save(buf, 'PNG', optimize=True)
            b = buf.getvalue()
            if len(b) == target:
                return b
            if len(b) + 20 <= target:
                pad = target - len(b) - 20
                return b[:-12] + chunk(b'tEXt', b'Comment\x00' + b'x' * pad) + b[-12:]
        if nw <= 16:
            return None
        s *= 0.85

for root, _, names in os.walk(os.path.join(app, "Frameworks")):
    for n in names:
        if not n.endswith(".dylib"):
            continue
        p = os.path.join(root, n)
        with open(p, 'rb') as f:
            data = f.read()
        new = bytearray(data)
        patched = 0
        for m in set(B64.findall(data)):
            try:
                orig = base64.b64decode(m)
            except Exception:
                continue
            wh = png_size(orig)
            if wh and looks_like_mascot(orig):
                png = make_png(len(orig), wh[0], wh[1])
                if png:
                    nb = base64.b64encode(png)
                    if len(nb) == len(m):
                        new = bytearray(bytes(new).replace(m, nb))
                        patched += 1
        if patched > 0:
            with open(p, 'wb') as f:
                f.write(bytes(new))
            print(f"  Patched {patched} embedded base64 icon(s) in {n}")
PY

  # 4) Copy custom menu icon & libashte.dylib into Frameworks
  mkdir -p "$APP/Frameworks"
  cp "$WORK/libashte.dylib" "$APP/Frameworks/libashte.dylib"
  resize "$MENU_ICON" 120 120 "$APP/ashte_menu_icon.png"

  # 5) Inject Load Command into the mod menu dylib using LIEF
  python3 - "$APP" <<'PY'
import os, sys, plistlib, lief

app = sys.argv[1]
target_bin = None

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

  # 6) Re-pack IPA
  (cd "$T" && zip -qry "$WORK/out/$fname" Payload)
done

echo "== Uploading to $TO_TAG"
gh release view "$TO_TAG" -R "$REPO" >/dev/null 2>&1 || \
  gh release create "$TO_TAG" -R "$REPO" -t "$TO_TAG" -n "Rebranded IPAs"
gh release upload "$TO_TAG" "$WORK"/out/*.ipa -R "$REPO" --clobber

rm -rf "$WORK/tmp"
echo "Done."
