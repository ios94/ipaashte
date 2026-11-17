#!/usr/bin/env bash
# ipa-rebrand.sh (Universal Multi-IPA Edition + Hardcore ViP Blocker)

set -euo pipefail

REPO="${REPO:-USERNAME/REPO}"
FROM_TAG="${FROM_TAG:-V.1}"
TO_TAG="${TO_TAG:-V.5}"
NEW_NAME="${NEW_NAME:-keep}"
NEW_LOGO="${NEW_LOGO:-logo.png}"
MENU_TITLE="${MENU_TITLE:-Ashte Mod}"
MENU_ICON="${MENU_ICON:-menu_icon.png}"
MENU_COLOR_HEX="${MENU_COLOR_HEX:-1E64E8}"
TELEGRAM_URL="${TELEGRAM_URL:-https://t.me/ashtemobile}"

if [[ ! -f "$MENU_ICON" ]]; then
  if [[ -f "$NEW_LOGO" ]]; then
    MENU_ICON="$NEW_LOGO"
  else
    echo "Menu icon not found: $MENU_ICON"
    exit 1
  fi
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

SAFE_TITLE=$(python3 -c 'import sys; print(sys.argv[1].replace("\\", "\\\\").replace("\"", "\\\""))' "$MENU_TITLE")
SAFE_URL=$(python3 -c 'import sys; print(sys.argv[1].replace("\\", "\\\\").replace("\"", "\\\""))' "$TELEGRAM_URL")

# 1) Build the Universal Runtime Objective-C Hook Dylib (libashte.dylib)
cat > "$WORK/ashte_hook.m" <<EOF
#import <UIKit/UIKit.h>
#import <objc/runtime.h>

static NSString *const kNewTitle = @"${SAFE_TITLE}";
static NSString *const kTelegramURL = @"${SAFE_URL}";

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
        if (r > 0.58 && g < 0.40 && b < 0.40 && a > 0.15) {
            if (isDarkHeader) *isDarkHeader = (r < 0.82);
            return YES;
        }
    }
    CGColorRef cg = color.CGColor;
    if (cg) {
        size_t n = CGColorGetNumberOfComponents(cg);
        const CGFloat *c = CGColorGetComponents(cg);
        if (c && n >= 3) {
            r = c[0]; g = c[1]; b = c[2];
            a = (n >= 4) ? c[3] : 1.0;
            if (r > 0.58 && g < 0.40 && b < 0.40 && a > 0.15) {
                if (isDarkHeader) *isDarkHeader = (r < 0.82);
                return YES;
            }
        }
    }
    return NO;
}

// پشکنینی هەموو جۆرە تێکستێک (ئاسایی، Attributed، دوگمە، Accessibility)
static BOOL isViPString(NSString *s) {
    if (!s || s.length < 5) return NO;
    if ([s rangeOfString:@"Join the ViP" options:NSCaseInsensitiveSearch].location != NSNotFound ||
        [s rangeOfString:@"Unlimited Feature Access" options:NSCaseInsensitiveSearch].location != NSNotFound ||
        [s rangeOfString:@"ViP purchases are non-refundable" options:NSCaseInsensitiveSearch].location != NSNotFound ||
        [s rangeOfString:@"Priority Requests" options:NSCaseInsensitiveSearch].location != NSNotFound ||
        [s rangeOfString:@"Get access to all hack features" options:NSCaseInsensitiveSearch].location != NSNotFound ||
        [s rangeOfString:@"Enjoy an ad-free experience" options:NSCaseInsensitiveSearch].location != NSNotFound ||
        [s isEqualToString:@"Maybe Later"] ||
        [s isEqualToString:@"Join Now!"]) {
        return YES;
    }
    return NO;
}

static NSString *extractViewText(UIView *view) {
    if (!view) return nil;
    if ([view isKindOfClass:[UILabel class]]) {
        UILabel *l = (UILabel *)view;
        if (l.text.length > 0) return l.text;
        if (l.attributedText.string.length > 0) return l.attributedText.string;
    } else if ([view isKindOfClass:[UIButton class]]) {
        UIButton *b = (UIButton *)view;
        NSString *t = [b titleForState:UIControlStateNormal] ?: b.titleLabel.text ?: b.currentAttributedTitle.string;
        if (t.length > 0) return t;
    } else if ([view isKindOfClass:[UITextView class]]) {
        UITextView *tv = (UITextView *)view;
        if (tv.text.length > 0) return tv.text;
        if (tv.attributedText.string.length > 0) return tv.attributedText.string;
    }
    if (view.accessibilityLabel.length > 0) return view.accessibilityLabel;
    return nil;
}

static BOOL containsViPPopupContent(UIView *view) {
    if (!view) return NO;
    NSString *cls = NSStringFromClass([view class]);
    if ([cls rangeOfString:@"VIP" options:NSCaseInsensitiveSearch].location != NSNotFound ||
        [cls rangeOfString:@"Upsell" options:NSCaseInsensitiveSearch].location != NSNotFound ||
        [cls rangeOfString:@"Paywall" options:NSCaseInsensitiveSearch].location != NSNotFound) {
        return YES;
    }
    NSString *txt = extractViewText(view);
    if (isViPString(txt)) return YES;

    for (UIView *sub in [view.subviews copy]) {
        if (containsViPPopupContent(sub)) return YES;
    }
    return NO;
}

// سڕینەوەی تەواوەتی پەنجەرەی ViP (چ ViewController بێت، چ UIWindow، چ Subview)
static void nukeViPFromView(UIView *view) {
    if (!view) return;

    // ئەگەر دوگمەی Maybe Later بوو، خۆکارانە دایبگرە با مۆدەکە خۆی دایبخات
    if ([view isKindOfClass:[UIButton class]]) {
        UIButton *btn = (UIButton *)view;
        NSString *bt = extractViewText(btn) ?: @"";
        if ([bt rangeOfString:@"Maybe Later" options:NSCaseInsensitiveSearch].location != NSNotFound) {
            [btn sendActionsForControlEvents:UIControlEventTouchUpInside];
        }
    }

    // ١) گەڕان بەدوای UIViewController بۆ داخستنی فەرمی
    UIResponder *resp = view;
    UIViewController *foundVC = nil;
    while (resp) {
        if ([resp isKindOfClass:[UIViewController class]]) {
            foundVC = (UIViewController *)resp;
            break;
        }
        resp = [resp nextResponder];
    }

    if (foundVC) {
        if (foundVC.presentingViewController) {
            [foundVC dismissViewControllerAnimated:NO completion:nil];
            return;
        }
        if (foundVC.navigationController && foundVC.navigationController.viewControllers.count > 1) {
            [foundVC.navigationController popViewControllerAnimated:NO];
            return;
        }
        if (foundVC.parentViewController) {
            [foundVC willMoveToParentViewController:nil];
            [foundVC.view removeFromSuperview];
            [foundVC removeFromParentViewController];
            return;
        }
    }

    // ٢) ئەگەر لەسەر UIWindowـی تایبەت بوو (کە iGameGod زۆرجار بەکاریدەهێنێت)
    UIWindow *win = view.window;
    UIWindow *mainWin = [UIApplication sharedApplication].delegate.window;
    if (win && win != mainWin && win.windowLevel >= UIWindowLevelNormal) {
        if (foundVC && win.rootViewController == foundVC) {
            win.hidden = YES;
            win.alpha = 0.0;
            win.userInteractionEnabled = NO;
            win.rootViewController = nil;
            return;
        }
    }

    // ٣) دۆزینەوەی گەورەترین قاڵبی پەنجەرەکە و شاردنەوەی
    UIView *container = view;
    while (container.superview &&
           ![container.superview isKindOfClass:[UIWindow class]] &&
           container.superview != mainWin.rootViewController.view) {
        container = container.superview;
    }
    container.hidden = YES;
    container.alpha = 0.0;
    container.userInteractionEnabled = NO;
    [container removeFromSuperview];
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

static void (*orig_viewDidAppear)(id, SEL, BOOL) = NULL;
static void hooked_viewDidAppear(UIViewController *self, SEL _cmd, BOOL animated) {
    orig_viewDidAppear(self, _cmd, animated);
    NSString *vcClass = NSStringFromClass([self class]);
    if ([vcClass rangeOfString:@"VIP" options:NSCaseInsensitiveSearch].location != NSNotFound ||
        containsViPPopupContent(self.view)) {
        nukeViPFromView(self.view);
    }
}

static void (*orig_presentVC)(id, SEL, UIViewController *, BOOL, void (^)(void)) = NULL;
static void hooked_presentVC(id self, SEL _cmd, UIViewController *vcToPresent, BOOL flag, void (^completion)(void)) {
    if (!vcToPresent) {
        orig_presentVC(self, _cmd, vcToPresent, flag, completion);
        return;
    }

    // Force view load to inspect its contents before presenting
    UIView *v = vcToPresent.view;
    [v layoutIfNeeded];

    NSString *vcClass = NSStringFromClass([vcToPresent class]);
    if ([vcClass rangeOfString:@"VIP" options:NSCaseInsensitiveSearch].location != NSNotFound ||
        [vcClass rangeOfString:@"Paywall" options:NSCaseInsensitiveSearch].location != NSNotFound ||
        containsViPPopupContent(v)) {
        if (completion) completion();
        return;
    }

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
                [at rangeOfString:@"Thank" options:NSCaseInsensitiveSearch].location != NSNotFound ||
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

static void scrubLayer(CALayer *layer) {
    if (!layer) return;
    BOOL isHeader = NO;
    if (layer.backgroundColor) {
        UIColor *c = [UIColor colorWithCGColor:layer.backgroundColor];
        if (isMenuRed(c, &isHeader)) {
            CGFloat a = CGColorGetAlpha(layer.backgroundColor);
            UIColor *nb = isHeader
                ? [UIColor colorWithRed:${HR_FLT} green:${HG_FLT} blue:${HB_FLT} alpha:a]
                : [UIColor colorWithRed:${R_FLT} green:${G_FLT} blue:${B_FLT} alpha:a];
            layer.backgroundColor = nb.CGColor;
        }
    }
    if (layer.borderColor) {
        UIColor *c = [UIColor colorWithCGColor:layer.borderColor];
        if (isMenuRed(c, NULL)) {
            layer.borderColor = [UIColor colorWithRed:${R_FLT} green:${G_FLT} blue:${B_FLT} alpha:1.0].CGColor;
        }
    }
    if ([layer isKindOfClass:[CAShapeLayer class]]) {
        CAShapeLayer *sl = (CAShapeLayer *)layer;
        if (sl.fillColor && isMenuRed([UIColor colorWithCGColor:sl.fillColor], &isHeader)) {
            sl.fillColor = [UIColor colorWithRed:${R_FLT} green:${G_FLT} blue:${B_FLT} alpha:1.0].CGColor;
        }
        if (sl.strokeColor && isMenuRed([UIColor colorWithCGColor:sl.strokeColor], &isHeader)) {
            sl.strokeColor = [UIColor colorWithRed:${HR_FLT} green:${HG_FLT} blue:${HB_FLT} alpha:1.0].CGColor;
        }
    }
    for (CALayer *sub in [layer.sublayers copy]) {
        scrubLayer(sub);
    }
}

static void scrubViewHierarchy(UIView *view) {
    if (!view || view.hidden) return;

    // 0. پشکنینی خێرا بۆ سڕینەوەی پەنجەرەی Join ViP
    NSString *vText = extractViewText(view);
    if (isViPString(vText)) {
        nukeViPFromView(view);
        return;
    }

    // 1. Change Red menu background, switch buttons & layers to custom color
    BOOL isHeader = NO;
    if (isMenuRed(view.backgroundColor, &isHeader)) {
        CGFloat alpha = CGColorGetAlpha(view.backgroundColor.CGColor);
        if (isHeader) {
            view.backgroundColor = [UIColor colorWithRed:${HR_FLT} green:${HG_FLT} blue:${HB_FLT} alpha:alpha];
        } else {
            view.backgroundColor = [UIColor colorWithRed:${R_FLT} green:${G_FLT} blue:${B_FLT} alpha:alpha];
        }
    }
    if (isMenuRed(view.tintColor, NULL)) {
        view.tintColor = [UIColor colorWithRed:${R_FLT} green:${G_FLT} blue:${B_FLT} alpha:1.0];
    }
    scrubLayer(view.layer);

    // 2. Change UISlider & UISwitch red tints
    if ([view isKindOfClass:[UISlider class]]) {
        UISlider *slider = (UISlider *)view;
        slider.minimumTrackTintColor = [UIColor colorWithRed:${HR_FLT} green:${HG_FLT} blue:${HB_FLT} alpha:1.0];
        slider.thumbTintColor = [UIColor colorWithRed:${R_FLT} green:${G_FLT} blue:${B_FLT} alpha:1.0];
    }
    if ([view isKindOfClass:[UISwitch class]]) {
        UISwitch *sw = (UISwitch *)view;
        sw.onTintColor = [UIColor colorWithRed:${R_FLT} green:${G_FLT} blue:${B_FLT} alpha:1.0];
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

    // 4. Replace mascot/avatar icon in menu header & floating button with custom logo
    UIImage *customImg = getCustomMenuIcon();
    if (customImg && view.tag != 994411) {
        CGSize sz = view.bounds.size;
        if (sz.width >= 20 && sz.width <= 105 && sz.height >= 20 && sz.height <= 105 && fabs(sz.width - sz.height) <= 18) {
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

    for (UIView *sub in [view.subviews copy]) {
        scrubViewHierarchy(sub);
    }
}

static NSArray<UIWindow *> *getAllWindows(void) {
    NSMutableSet *set = [NSMutableSet set];
    UIApplication *app = [UIApplication sharedApplication];
    if (app.windows) [set addObjectsFromArray:app.windows];
    if (app.keyWindow) [set addObject:app.keyWindow];
    if (@available(iOS 13.0, *)) {
        for (UIScene *scene in app.connectedScenes) {
            if ([scene isKindOfClass:[UIWindowScene class]]) {
                UIWindowScene *ws = (UIWindowScene *)scene;
                if (ws.windows) [set addObjectsFromArray:ws.windows];
            }
        }
    }
    return [set allObjects];
}

__attribute__((constructor))
static void initAshteHook(void) {
    Method mPres = class_getInstanceMethod([UIViewController class], @selector(presentViewController:animated:completion:));
    if (mPres) {
        orig_presentVC = (void *)method_getImplementation(mPres);
        method_setImplementation(mPres, (IMP)hooked_presentVC);
    }

    Method mAppear = class_getInstanceMethod([UIViewController class], @selector(viewDidAppear:));
    if (mAppear) {
        orig_viewDidAppear = (void *)method_getImplementation(mAppear);
        method_setImplementation(mAppear, (IMP)hooked_viewDidAppear);
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
        [NSTimer scheduledTimerWithTimeInterval:0.08 repeats:YES block:^(NSTimer * _Nonnull timer) {
            for (UIWindow *win in getAllWindows()) {
                if (win.hidden) continue;
                UIViewController *topVC = win.rootViewController;
                while (topVC.presentedViewController) {
                    topVC = topVC.presentedViewController;
                }
                if (topVC && containsViPPopupContent(topVC.view)) {
                    nukeViPFromView(topVC.view);
                }
                scrubViewHierarchy(win);
            }
        }];
    });
}
EOF

echo "== Compiling Universal iOS ARM64 Hook (libashte.dylib)"
SDK_PATH="$(xcrun --sdk iphoneos --show-sdk-path)"
xcrun --sdk iphoneos clang -arch arm64 -dynamiclib \
  -isysroot "$SDK_PATH" \
  -miphoneos-version-min=12.0 \
  -framework UIKit -framework Foundation -framework CoreGraphics \
  -framework QuartzCore \
  -install_name "@executable_path/libashte.dylib" \
  "$WORK/ashte_hook.m" -o "$WORK/libashte.dylib"

echo "== Downloading ALL IPAs from $FROM_TAG"
gh release download "$FROM_TAG" -R "$REPO" -p "*.ipa" -D "$WORK/in"

for ipa in "$WORK"/in/*.ipa; do
  fname="$(basename "$ipa")"
  echo "=========================================="
  echo "== Processing: $fname"
  T="$WORK/tmp"
  rm -rf "$T"
  mkdir -p "$T"
  unzip -q "$ipa" -d "$T"
  APP="$(ls -d "$T"/Payload/*.app | head -n1)"

  find "$APP" -name "_CodeSignature" -type d -exec rm -rf {} +

  # 1) Keep original game name unless user explicitly typed a custom name
  if [[ -n "$NEW_NAME" && "$NEW_NAME" != "My App" && "$NEW_NAME" != "keep" ]]; then
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
  fi

  # 2) Patch embedded base64 icons & plain text titles inside ANY dylib in the entire app
  python3 - "$APP" "$MENU_ICON" "$MENU_TITLE" <<'PY'
import sys, os, re, io, base64, struct, zlib
from PIL import Image

app, icon_path, title = sys.argv[1:4]
B64 = re.compile(rb'iVBORw0KGgo[A-Za-z0-9+/]{80,}={0,2}')
MACHO = (b'\xcf\xfa\xed\xfe', b'\xca\xfe\xba\xbe', b'\xbe\xba\xfe\xca')

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

rep20 = title.encode('utf-8')[:20].ljust(20, b' ')

for root, _, names in os.walk(app):
    for n in names:
        p = os.path.join(root, n)
        if os.path.islink(p) or not os.path.isfile(p):
            continue
        if not (n.endswith(".dylib") or 'igamegod' in n.lower()):
            continue
        with open(p, 'rb') as f:
            data = f.read()
        if data[:4] not in MACHO:
            continue
        new = bytearray(data)
        patched = 0
        for pat in (b"Made for iOSGods.com", b"made for iosgods.com"):
            if pat in new:
                new = bytearray(bytes(new).replace(pat, rep20))
                patched += 1
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
        if bytes(new) != data:
            with open(p, 'wb') as f:
                f.write(bytes(new))
            print(f"  Binary-patched {patched} item(s) in {os.path.relpath(p, app)}")
PY

  # 3) Place libashte.dylib in BOTH app root (@executable_path) and Frameworks/ (@rpath)
  cp "$WORK/libashte.dylib" "$APP/libashte.dylib"
  mkdir -p "$APP/Frameworks"
  cp "$WORK/libashte.dylib" "$APP/Frameworks/libashte.dylib"
  resize "$MENU_ICON" 120 120 "$APP/ashte_menu_icon.png"

  # 4) Universal Injection: Inject into ALL mod dylibs + Main Executable (Every binary loads it!)
  python3 - "$APP" <<'PY'
import os, sys, plistlib, lief

app = sys.argv[1]
with open(os.path.join(app, "Info.plist"), "rb") as f:
    main_exe = plistlib.load(f).get("CFBundleExecutable", "")

targets = []
for root, _, names in os.walk(app):
    for n in names:
        if n.endswith(".dylib") and n not in ("libashte.dylib", "CydiaSubstrate.dylib", "libsubstitute.dylib", "libellekit.dylib"):
            targets.append(os.path.join(root, n))

main_path = os.path.join(app, main_exe)
if os.path.isfile(main_path):
    targets.append(main_path)

dylib_ref = "@executable_path/libashte.dylib"

for t in targets:
    rel = os.path.relpath(t, app)
    try:
        b = lief.parse(t)
        if b:
            existing = [lib.name for lib in b.libraries]
            if dylib_ref in existing:
                print(f"  Already linked in {rel}")
                continue
            b.add_library(dylib_ref)
            b.write(t)
            print(f"  Injected {dylib_ref} -> {rel}")
    except Exception as e:
        print(f"  Skipped {rel}: {e}")
PY

  # 5) Re-pack IPA with its original filename
  (cd "$T" && zip -qry "$WORK/out/$fname" Payload)
done

echo "== Uploading all rebranded IPAs to $TO_TAG"
gh release view "$TO_TAG" -R "$REPO" >/dev/null 2>&1 || \
  gh release create "$TO_TAG" -R "$REPO" -t "$TO_TAG" -n "Rebranded IPAs"
gh release upload "$TO_TAG" "$WORK"/out/*.ipa -R "$REPO" --clobber

rm -rf "$WORK/tmp"
echo "Done."
