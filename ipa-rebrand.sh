#!/usr/bin/env bash
# ipa-rebrand.sh (Universal Frameworks Injection + Auto-Kill "Join ViP" + Blue Menu + Telegram Popup + Check0ver rename)

set -euo pipefail

REPO="${REPO:-USERNAME/REPO}"
FROM_TAG="${FROM_TAG:-V.1}"
TO_TAG="${TO_TAG:-V.5}"
NEW_NAME="${NEW_NAME:-keep}"
GAME="${GAME:-all}"                 # all = every game, or part of the IPA file name
SKIP_EXISTING="${SKIP_EXISTING:-true}"  # true = skip IPAs already uploaded to TO_TAG
IPA_LINK="${IPA_LINK:-}"             # optional: full release link of ONE ipa to process

LINK_FILE=""
DIRECT_URL=""
SRC_REPO=""
if [[ -n "$IPA_LINK" ]]; then
  SKIP_EXISTING="false"
  case "$IPA_LINK" in
    https://github.com/*/releases/download/*/*)
      # GitHub release asset (this repo or any other repo)
      SRC_REPO="${IPA_LINK#https://github.com/}"
      SRC_REPO="${SRC_REPO%%/releases/*}"
      rest="${IPA_LINK#*/releases/download/}"
      FROM_TAG="$(python3 -c 'import sys,urllib.parse as u;print(u.unquote(sys.argv[1]))' "${rest%%/*}")"
      LINK_FILE="$(python3 -c 'import sys,urllib.parse as u;print(u.unquote(sys.argv[1]))' "${rest#*/}")"
      echo "== GitHub release link: repo=$SRC_REPO tag=$FROM_TAG file=$LINK_FILE"
      ;;
    http://*|https://*)
      # Any other direct link (Dropbox, Google Drive, your own server, ...)
      DIRECT_URL="$IPA_LINK"
      echo "== Direct link mode"
      ;;
    *)
      echo "Bad link. It must start with http:// or https://"
      exit 1
      ;;
  esac
fi
NEW_LOGO="${NEW_LOGO:-logo.png}"
MENU_TITLE="${MENU_TITLE:-Ashte Mod}"
MENU_ICON="${MENU_ICON:-menu_icon.png}"
MENU_COLOR_HEX="${MENU_COLOR_HEX:-1E64E8}"
MENU_MODERN="${MENU_MODERN:-true}"   # true = rounded/modern menu look, false = keep original shape
if [[ "$MENU_MODERN" == "true" ]]; then MODERN_FLAG=1; else MODERN_FLAG=0; fi
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

# 1) Build the Universal Runtime Objective-C Hook Dylib (libashte.dylib)
cat > "$WORK/ashte_hook.m" <<EOF
#import <UIKit/UIKit.h>
#import <WebKit/WebKit.h>
#import <SafariServices/SafariServices.h>
#import <objc/runtime.h>

static NSString *const kNewTitle = @"${MENU_TITLE}";
static const BOOL kAshteModern = ${MODERN_FLAG};
static NSString *const kTelegramURL = @"${TELEGRAM_URL}";
static NSHashTable<UIWindow *> *gKnownWindows = nil;

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

// Extracts text from ANY UIView (UILabel, UIButton, UITextView, AttributedText, iOS 15+ UIButtonConfiguration, CATextLayer)
static NSString *extractViewText(UIView *view) {
    if (!view) return nil;
    NSMutableString *out = [NSMutableString string];

    if ([view isKindOfClass:[UILabel class]]) {
        UILabel *lbl = (UILabel *)view;
        if (lbl.text) [out appendFormat:@"%@ ", lbl.text];
        if (lbl.attributedText.string) [out appendFormat:@"%@ ", lbl.attributedText.string];
    } else if ([view isKindOfClass:[UIButton class]]) {
        UIButton *btn = (UIButton *)view;
        NSString *t1 = [btn titleForState:UIControlStateNormal];
        NSString *t2 = btn.titleLabel.text;
        NSString *t3 = [btn attributedTitleForState:UIControlStateNormal].string;
        NSString *t4 = btn.titleLabel.attributedText.string;
        if (t1) [out appendFormat:@"%@ ", t1];
        if (t2) [out appendFormat:@"%@ ", t2];
        if (t3) [out appendFormat:@"%@ ", t3];
        if (t4) [out appendFormat:@"%@ ", t4];
        if (@available(iOS 15.0, *)) {
            if (btn.configuration.title) [out appendFormat:@"%@ ", btn.configuration.title];
            if (btn.configuration.attributedTitle.string) [out appendFormat:@"%@ ", btn.configuration.attributedTitle.string];
        }
    } else if ([view isKindOfClass:[UITextView class]]) {
        UITextView *tv = (UITextView *)view;
        if (tv.text) [out appendFormat:@"%@ ", tv.text];
        if (tv.attributedText.string) [out appendFormat:@"%@ ", tv.attributedText.string];
    }

    if ([view.layer isKindOfClass:[CATextLayer class]]) {
        id s = ((CATextLayer *)view.layer).string;
        if ([s isKindOfClass:[NSString class]]) [out appendFormat:@"%@ ", s];
        else if ([s isKindOfClass:[NSAttributedString class]]) [out appendFormat:@"%@ ", ((NSAttributedString *)s).string];
    }

    return out.length > 0 ? out : nil;
}

static BOOL containsVipKeywords(NSString *s) {
    if (!s || s.length == 0) return NO;
    NSArray<NSString *> *keys = @[
        @"Join the ViP",
        @"Unlimited Feature Access",
        @"Priority Requests",
        @"Priority Support",
        @"Support Development",
        @"non-refundable",
        @"ViP Terms",
        @"Maybe Later",
        @"Join Now!",
        @"iOSGods Apps"
    ];
    for (NSString *k in keys) {
        if ([s rangeOfString:k options:NSCaseInsensitiveSearch].location != NSNotFound) {
            return YES;
        }
    }
    return NO;
}

static BOOL isJoinVipHierarchy(UIView *root) {
    if (!root) return NO;
    NSString *txt = extractViewText(root);
    if (containsVipKeywords(txt)) return YES;

    for (UIView *sub in [root.subviews copy]) {
        if (isJoinVipHierarchy(sub)) return YES;
    }
    return NO;
}

static UIViewController *findOwningViewController(UIView *view) {
    UIResponder *r = view.nextResponder;
    while (r) {
        if ([r isKindOfClass:[UIViewController class]]) {
            return (UIViewController *)r;
        }
        r = r.nextResponder;
    }
    return nil;
}

// Fires "Maybe Later" button or tap gesture if found
static BOOL clickMaybeLater(UIView *root) {
    if (!root) return NO;
    NSString *txt = extractViewText(root);
    if (txt && [txt rangeOfString:@"Maybe Later" options:NSCaseInsensitiveSearch].location != NSNotFound) {
        if ([root isKindOfClass:[UIControl class]]) {
            [(UIControl *)root sendActionsForControlEvents:UIControlEventTouchUpInside];
            return YES;
        }
        UIView *p = root;
        while (p) {
            if ([p isKindOfClass:[UIControl class]]) {
                [(UIControl *)p sendActionsForControlEvents:UIControlEventTouchUpInside];
                return YES;
            }
            p = p.superview;
        }
    }
    for (UIView *sub in [root.subviews copy]) {
        if (clickMaybeLater(sub)) return YES;
    }
    return NO;
}

static void nukeVipControllerOrView(UIView *vipView) {
    if (!vipView) return;
    clickMaybeLater(vipView);

    UIViewController *vc = findOwningViewController(vipView);
    if (vc) {
        if (vc.presentingViewController) {
            [vc dismissViewControllerAnimated:NO completion:nil];
            return;
        }
        if (vc.navigationController && vc.navigationController.presentingViewController) {
            [vc.navigationController dismissViewControllerAnimated:NO completion:nil];
            return;
        }
    }

    // If added directly to a window or custom overlay window
    UIWindow *win = vipView.window;
    if (win && win != [UIApplication sharedApplication].windows.firstObject) {
        if (isJoinVipHierarchy(win)) {
            win.hidden = YES;
            win.alpha = 0.0;
            win.userInteractionEnabled = NO;
            return;
        }
    }

    vipView.hidden = YES;
    vipView.alpha = 0.0;
    vipView.userInteractionEnabled = NO;
    [vipView removeFromSuperview];
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

// Heart button: its x.com / twitter.com page is shown in an in-app Safari view.
// Only that page is replaced by the Telegram app. Nothing else is touched.
static const void *kHeartKey = &kHeartKey;
static BOOL isHeartLink(NSURL *url) {
    NSString *s = url.absoluteString.lowercaseString ?: @"";
    if ([s containsString:@"iosgods"]) return NO;
    NSString *host = url.host.lowercaseString ?: @"";
    return [host isEqualToString:@"x.com"] || [host hasSuffix:@".x.com"] ||
           [host isEqualToString:@"twitter.com"] || [host hasSuffix:@".twitter.com"];
}

static id (*orig_sfInitCfg)(id, SEL, NSURL *, SFSafariViewControllerConfiguration *) = NULL;
static id hooked_sfInitCfg(id self, SEL _cmd, NSURL *url, SFSafariViewControllerConfiguration *cfg) {
    id obj = orig_sfInitCfg(self, _cmd, url, cfg);
    if (obj && isHeartLink(url)) objc_setAssociatedObject(obj, kHeartKey, @YES, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    return obj;
}

static id (*orig_sfInitReader)(id, SEL, NSURL *, BOOL) = NULL;
static id hooked_sfInitReader(id self, SEL _cmd, NSURL *url, BOOL reader) {
    id obj = orig_sfInitReader(self, _cmd, url, reader);
    if (obj && isHeartLink(url)) objc_setAssociatedObject(obj, kHeartKey, @YES, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    return obj;
}

// Hook UIViewController viewDidAppear: to immediately dismiss any "Join ViP" modal VC
static void (*orig_viewDidAppear)(UIViewController *, SEL, BOOL) = NULL;
static void hooked_viewDidAppear(UIViewController *self, SEL _cmd, BOOL animated) {
    orig_viewDidAppear(self, _cmd, animated);
    if (![self isKindOfClass:[UIAlertController class]]) {
        NSString *cls = NSStringFromClass([self class]).lowercaseString ?: @"";
        if ([cls containsString:@"vip"] || [cls containsString:@"paywall"] || isJoinVipHierarchy(self.view)) {
            nukeVipControllerOrView(self.view);
        }
    }
}

// Intercept UIViewController presentViewController
static void (*orig_presentVC)(id, SEL, UIViewController *, BOOL, void (^)(void)) = NULL;
static void hooked_presentVC(id self, SEL _cmd, UIViewController *vcToPresent, BOOL flag, void (^completion)(void)) {
    if (!vcToPresent) {
        orig_presentVC(self, _cmd, vcToPresent, flag, completion);
        return;
    }

    if ([vcToPresent isKindOfClass:[SFSafariViewController class]] &&
        objc_getAssociatedObject(vcToPresent, kHeartKey)) {
        openTelegramChannel();
        if (completion) completion();
        return;
    }

    NSString *vcClass = NSStringFromClass([vcToPresent class]).lowercaseString ?: @"";
    if ([vcClass containsString:@"vip"] || [vcClass containsString:@"paywall"]) {
        if (completion) completion();
        return;
    }

    if (![vcToPresent isKindOfClass:[UIAlertController class]]) {
        [vcToPresent loadViewIfNeeded];
        if (isJoinVipHierarchy(vcToPresent.view)) {
            if (completion) completion();
            return;
        }
        if ([vcToPresent isKindOfClass:[UINavigationController class]]) {
            UINavigationController *nav = (UINavigationController *)vcToPresent;
            for (UIViewController *child in nav.viewControllers) {
                [child loadViewIfNeeded];
                if (isJoinVipHierarchy(child.view)) {
                    if (completion) completion();
                    return;
                }
            }
        }
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

// Track every UIWindow in the app (even private overlay windows created by iGameGod/iOSGods)
static void (*orig_didMoveToWindow)(UIView *, SEL) = NULL;
static void hooked_didMoveToWindow(UIView *self, SEL _cmd) {
    orig_didMoveToWindow(self, _cmd);
    if (self.window && gKnownWindows) {
        [gKnownWindows addObject:self.window];
    }
    NSString *txt = extractViewText(self);
    if (containsVipKeywords(txt)) {
        dispatch_async(dispatch_get_main_queue(), ^{
            UIView *top = self;
            while (top.superview && ![top.superview isKindOfClass:[UIWindow class]]) {
                top = top.superview;
            }
            nukeVipControllerOrView(top);
        });
    }
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

// ---- Blue menu recolor (only inside the menu box) ----
static BOOL isMenuBlue(UIColor *color, BOOL *isDark) {
    if (!color) return NO;
    CGFloat r = 0, g = 0, b = 0, a = 0;
    if (![color getRed:&r green:&g blue:&b alpha:&a]) {
        CGColorRef cg = color.CGColor;
        size_t n = CGColorGetNumberOfComponents(cg);
        const CGFloat *c = CGColorGetComponents(cg);
        if (!c || n < 3) return NO;
        r = c[0]; g = c[1]; b = c[2];
        a = (n >= 4) ? c[3] : 1.0;
    }
    if (a > 0.15 && b > 0.35 && b > r + 0.20 && b >= g) {
        if (isDark) *isDark = (b < 0.75);
        return YES;
    }
    return NO;
}

static UIColor *ashteBlueRepl(BOOL dark, CGFloat a) {
    return dark
        ? [UIColor colorWithRed:${HR_FLT} green:${HG_FLT} blue:${HB_FLT} alpha:a]
        : [UIColor colorWithRed:${R_FLT} green:${G_FLT} blue:${B_FLT} alpha:a];
}

static void recolorBlueLayer(CALayer *layer) {
    if (!layer) return;
    BOOL d = NO;
    if (layer.backgroundColor) {
        UIColor *c = [UIColor colorWithCGColor:layer.backgroundColor];
        if (isMenuBlue(c, &d)) {
            layer.backgroundColor = ashteBlueRepl(d, CGColorGetAlpha(layer.backgroundColor)).CGColor;
        }
    }
    if ([layer isKindOfClass:[CAGradientLayer class]]) {
        CAGradientLayer *gl = (CAGradientLayer *)layer;
        NSMutableArray *arr = [NSMutableArray array];
        BOOL changed = NO;
        for (id col in gl.colors) {
            CGColorRef cg = (__bridge CGColorRef)col;
            if (isMenuBlue([UIColor colorWithCGColor:cg], &d)) {
                [arr addObject:(id)ashteBlueRepl(d, CGColorGetAlpha(cg)).CGColor];
                changed = YES;
            } else {
                [arr addObject:col];
            }
        }
        if (changed) gl.colors = arr;
    }
    if ([layer isKindOfClass:[CAShapeLayer class]]) {
        CAShapeLayer *sl = (CAShapeLayer *)layer;
        if (sl.fillColor && isMenuBlue([UIColor colorWithCGColor:sl.fillColor], &d)) {
            sl.fillColor = ashteBlueRepl(d, 1.0).CGColor;
        }
    }
    for (CALayer *sub in [layer.sublayers copy]) recolorBlueLayer(sub);
}

static void recolorBlueView(UIView *v) {
    if (!v) return;
    BOOL d = NO;
    if (isMenuBlue(v.backgroundColor, &d)) {
        v.backgroundColor = ashteBlueRepl(d, CGColorGetAlpha(v.backgroundColor.CGColor));
    }
    if (isMenuBlue(v.tintColor, &d)) v.tintColor = ashteBlueRepl(NO, 1.0);
    recolorBlueLayer(v.layer);
    for (UIView *sub in [v.subviews copy]) recolorBlueView(sub);
}

// Finds the menu box (smaller than the screen) that contains the title label
static UIView *findMenuRoot(UIView *label) {
    UIWindow *win = label.window;
    if (!win) return nil;
    CGSize ws = win.bounds.size;
    UIView *best = nil;
    UIView *p = label.superview;
    while (p && p != win) {
        CGSize s = p.bounds.size;
        if (s.width < ws.width * 0.92 && s.height < ws.height * 0.92) best = p;
        else break;
        p = p.superview;
    }
    return best;
}

// ---- Modern menu look (rounded, soft shadow, cleaner text) ----
static NSHashTable *gAshteStyled = nil;

static BOOL ashteAccentIsLight(void) {
    CGFloat r = 0, g = 0, b = 0, a = 0;
    [ashteBlueRepl(NO, 1.0) getRed:&r green:&g blue:&b alpha:&a];
    return (0.299 * r + 0.587 * g + 0.114 * b) > 0.62;
}

static BOOL ashteIsDarkText(UIColor *c) {
    if (!c) return YES;
    CGFloat r = 0, g = 0, b = 0, a = 0, w = 0;
    if ([c getRed:&r green:&g blue:&b alpha:&a]) {
        return (0.299 * r + 0.587 * g + 0.114 * b) < 0.35;
    }
    if ([c getWhite:&w alpha:&a]) return w < 0.35;
    return NO;
}

static void ashteStyleTree(UIView *v, UIView *root, BOOL light) {
    if (!v) return;
    if ([v isKindOfClass:[UILabel class]]) {
        UILabel *l = (UILabel *)v;
        if (![gAshteStyled containsObject:l]) {
            [gAshteStyled addObject:l];
            NSCharacterSet *ws = [NSCharacterSet whitespaceAndNewlineCharacterSet];
            NSString *t = [l.text stringByTrimmingCharactersInSet:ws];
            NSString *nt = [kNewTitle stringByTrimmingCharactersInSet:ws];
            BOOL isTitle = (t.length > 0 && [t caseInsensitiveCompare:nt] == NSOrderedSame);
            CGFloat sz = l.font ? l.font.pointSize : 16.0;
            l.font = [UIFont systemFontOfSize:sz weight:(isTitle ? UIFontWeightBold : UIFontWeightSemibold)];
            if (!light && ashteIsDarkText(l.textColor)) {
                l.textColor = [UIColor whiteColor];
            }
        }
    } else if (v != root && v.bounds.size.height <= 1.6 && v.bounds.size.width >= root.bounds.size.width * 0.5) {
        v.backgroundColor = light ? [UIColor colorWithWhite:0.0 alpha:0.12]
                                  : [UIColor colorWithWhite:1.0 alpha:0.28];
    }
    for (UIView *sub in [v.subviews copy]) ashteStyleTree(sub, root, light);
}

static void ashteModernize(UIView *root) {
    if (!root) return;
    @try {
        UIWindow *win = root.window;
        if (!win) return;
        CGSize ws = win.bounds.size;
        CGSize rs = root.bounds.size;
        // Safety: only touch a box that really looks like the menu (not a full-screen container)
        if (rs.width < 120.0 || rs.height < 80.0) return;
        if (rs.width > ws.width * 0.92 || rs.height > ws.height * 0.80) return;

        if (!gAshteStyled) gAshteStyled = [NSHashTable weakObjectsHashTable];
        BOOL light = ashteAccentIsLight();

        root.layer.cornerRadius = 18.0;
        root.layer.masksToBounds = YES;
        root.layer.borderWidth = 1.0;
        root.layer.borderColor = [UIColor colorWithWhite:1.0 alpha:0.30].CGColor;

        ashteStyleTree(root, root, light);
    } @catch (NSException *e) {
    }
}

static BOOL isIOSGodsNoticeText(NSString *s) {
    if (!s || s.length == 0) return NO;
    NSArray<NSString *> *keys = @[
        @"You must login",
        @"official topic",
        @"to activate this cheat",
        @"Cheats by",
        @"Hacks by"
    ];
    for (NSString *k in keys) {
        if ([s rangeOfString:k options:NSCaseInsensitiveSearch].location != NSNotFound) {
            return YES;
        }
    }
    return NO;
}

static void scrubViewHierarchy(UIView *view) {
    if (!view || view.hidden) return;

    // 0. If this view or WKWebView is the "Join ViP" screen, kill it immediately!
    NSString *vTxt = extractViewText(view);
    if (containsVipKeywords(vTxt)) {
        UIView *top = view;
        while (top.superview && ![top.superview isKindOfClass:[UIWindow class]]) {
            top = top.superview;
        }
        nukeVipControllerOrView(top);
        return;
    }
    if ([view isKindOfClass:[WKWebView class]] && view.tag != 554433) {
        view.tag = 554433;
        WKWebView *wv = (WKWebView *)view;
        [wv evaluateJavaScript:@"document.body ? document.body.innerText : ''" completionHandler:^(id res, NSError *err) {
            if ([res isKindOfClass:[NSString class]] && containsVipKeywords((NSString *)res)) {
                [wv evaluateJavaScript:@"Array.from(document.querySelectorAll('*')).find(e => e.textContent.trim()==='Maybe Later')?.click();" completionHandler:nil];
                nukeVipControllerOrView(wv);
            } else {
                view.tag = 0;
            }
        }];
    }

    // 1. Change Red menu background, switch buttons & layers to Blue
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

    // 2. Change UISlider & UISwitch red tints to Blue
    if ([view isKindOfClass:[UISlider class]]) {
        UISlider *slider = (UISlider *)view;
        slider.minimumTrackTintColor = [UIColor colorWithRed:${HR_FLT} green:${HG_FLT} blue:${HB_FLT} alpha:1.0];
        slider.thumbTintColor = [UIColor colorWithRed:${R_FLT} green:${G_FLT} blue:${B_FLT} alpha:1.0];
    }
    if ([view isKindOfClass:[UISwitch class]]) {
        UISwitch *sw = (UISwitch *)view;
        sw.onTintColor = [UIColor colorWithRed:${R_FLT} green:${G_FLT} blue:${B_FLT} alpha:1.0];
    }

    // 2b. Remove the iOSGods notice text and the "More Apps & Hacks" button (keep "Thank you!")
    if ([view isKindOfClass:[UIButton class]]) {
        NSString *bt = extractViewText(view);
        if (bt && [bt rangeOfString:@"More Apps" options:NSCaseInsensitiveSearch].location != NSNotFound) {
            view.hidden = YES;
            view.alpha = 0.0;
            view.userInteractionEnabled = NO;
            [view removeFromSuperview];
            return;
        }
    }
    if ([view isKindOfClass:[UILabel class]] || [view isKindOfClass:[UITextView class]]) {
        if (isIOSGodsNoticeText(extractViewText(view))) {
            if ([view isKindOfClass:[UILabel class]]) {
                ((UILabel *)view).text = @"";
                ((UILabel *)view).attributedText = nil;
            } else {
                ((UITextView *)view).text = @"";
                ((UITextView *)view).attributedText = nil;
            }
            view.hidden = YES;
            view.alpha = 0.0;
            return;
        }
    }

    // 3. Change Labels ("Made for iOSGods.com" / "Check0ver Team" -> Ashte Mod)
    if ([view isKindOfClass:[UILabel class]]) {
        UILabel *lbl = (UILabel *)view;
        NSString *txt = lbl.text ?: lbl.attributedText.string;
        if (txt) {
            if ([txt rangeOfString:@"Check0ver" options:NSCaseInsensitiveSearch].location != NSNotFound ||
                [txt rangeOfString:@"Checkover" options:NSCaseInsensitiveSearch].location != NSNotFound) {
                lbl.text = kNewTitle;
            } else if ([txt rangeOfString:@"Twitter" options:NSCaseInsensitiveSearch].location != NSNotFound) {
                lbl.text = @"Telegram";
            } else if ([txt rangeOfString:@"iOSGods" options:NSCaseInsensitiveSearch].location != NSNotFound ||
                       [txt rangeOfString:@"Made for" options:NSCaseInsensitiveSearch].location != NSNotFound) {
                lbl.text = kNewTitle;
            }
        }
    }

    // 3b. Recolor the blue menu (only inside the menu box)
    if ([view isKindOfClass:[UILabel class]]) {
        NSCharacterSet *ws = [NSCharacterSet whitespaceAndNewlineCharacterSet];
        NSString *tt = [((UILabel *)view).text stringByTrimmingCharactersInSet:ws];
        NSString *nt = [kNewTitle stringByTrimmingCharactersInSet:ws];
        if (tt.length > 0 && nt.length > 0 && [tt caseInsensitiveCompare:nt] == NSOrderedSame) {
            UIView *root = findMenuRoot(view);
            if (!root) root = view.superview.superview;
            if (root) {
                recolorBlueView(root);
                if (kAshteModern) ashteModernize(root);
            }
        }
    }

    // 4. Replace mascot/avatar icon in menu header & floating button with custom logo
    //    (square-ish icons, and the taller Check0ver mascot that overhangs the header)
    UIImage *customImg = getCustomMenuIcon();
    if (customImg && view.tag != 994411) {
        CGSize sz = view.bounds.size;
        BOOL squareish = (sz.width >= 20 && sz.width <= 105 && sz.height >= 20 && sz.height <= 105 && fabs(sz.width - sz.height) <= 18);
        BOOL tallMascot = (sz.width >= 50 && sz.width <= 105 && sz.height > sz.width && sz.height <= 140 && sz.height <= sz.width * 1.7);
        if (squareish || tallMascot) {
            if ([view isKindOfClass:[UIImageView class]]) {
                UIImageView *iv = (UIImageView *)view;
                if (iv.image && iv.frame.origin.x < 120) {
                    iv.image = customImg;
                    iv.contentMode = UIViewContentModeScaleAspectFit;
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
    if (gKnownWindows) {
        for (UIWindow *w in gKnownWindows) {
            if (w) [set addObject:w];
        }
    }
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
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        gKnownWindows = [NSHashTable weakObjectsHashTable];

        Method mPres = class_getInstanceMethod([UIViewController class], @selector(presentViewController:animated:completion:));
        if (mPres) {
            orig_presentVC = (void *)method_getImplementation(mPres);
            method_setImplementation(mPres, (IMP)hooked_presentVC);
        }

        Method mDidApp = class_getInstanceMethod([UIViewController class], @selector(viewDidAppear:));
        if (mDidApp) {
            orig_viewDidAppear = (void *)method_getImplementation(mDidApp);
            method_setImplementation(mDidApp, (IMP)hooked_viewDidAppear);
        }

        Method mMoveWin = class_getInstanceMethod([UIView class], @selector(didMoveToWindow));
        if (mMoveWin) {
            orig_didMoveToWindow = (void *)method_getImplementation(mMoveWin);
            method_setImplementation(mMoveWin, (IMP)hooked_didMoveToWindow);
        }

        Method mSfCfg = class_getInstanceMethod([SFSafariViewController class], @selector(initWithURL:configuration:));
        if (mSfCfg) {
            orig_sfInitCfg = (void *)method_getImplementation(mSfCfg);
            method_setImplementation(mSfCfg, (IMP)hooked_sfInitCfg);
        }
        Method mSfRd = class_getInstanceMethod([SFSafariViewController class], @selector(initWithURL:entersReaderIfAvailable:));
        if (mSfRd) {
            orig_sfInitReader = (void *)method_getImplementation(mSfRd);
            method_setImplementation(mSfRd, (IMP)hooked_sfInitReader);
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
            [NSTimer scheduledTimerWithTimeInterval:0.10 repeats:YES block:^(NSTimer * _Nonnull timer) {
                for (UIWindow *win in getAllWindows()) {
                    scrubViewHierarchy(win);
                }
            }];
        });
    });
}
EOF

echo "== Compiling Universal iOS ARM64 Hook (libashte.dylib)"
SDK_PATH="$(xcrun --sdk iphoneos --show-sdk-path)"
xcrun --sdk iphoneos clang -arch arm64 -dynamiclib \
  -isysroot "$SDK_PATH" \
  -miphoneos-version-min=12.0 \
  -framework UIKit -framework Foundation -framework CoreGraphics \
  -framework QuartzCore -framework WebKit -framework SafariServices \
  -install_name "@executable_path/Frameworks/libashte.dylib" \
  "$WORK/ashte_hook.m" -o "$WORK/libashte.dylib"

download_direct() {
  local url="$1"
  local hdr="$WORK/dl_headers.txt" tmp="$WORK/dl_file.bin"
  mkdir -p "$WORK/in"
  rm -f "$hdr" "$tmp"
  url="$(python3 - "$url" <<'PYN'
import sys, re
u = sys.argv[1].strip()
if 'dropbox.com' in u:
    if re.search(r'([?&])dl=0', u):
        u = re.sub(r'([?&])dl=0', r'\1dl=1', u)
    elif 'dl=1' not in u:
        u += ('&' if '?' in u else '?') + 'dl=1'
m = re.search(r'drive\.google\.com/file/d/([A-Za-z0-9_-]+)', u) or re.search(r'drive\.google\.com/.*[?&]id=([A-Za-z0-9_-]+)', u)
if m:
    u = 'https://drive.usercontent.google.com/download?id=%s&export=download&confirm=t' % m.group(1)
print(u)
PYN
)"
  echo "== Downloading: $url"
  curl -L --fail --retry 3 --connect-timeout 30 -A "Mozilla/5.0" -D "$hdr" -o "$tmp" "$url"
  local name
  name="$(python3 - "$hdr" "$url" <<'PYN'
import sys, re, urllib.parse as up
hdr, url = sys.argv[1], sys.argv[2]
name = ''
try:
    txt = open(hdr, encoding='latin-1').read()
    ms = re.findall(r"(?im)^content-disposition:.*$", txt)
    if ms:
        m = re.search(r"filename\*=(?:UTF-8'')?([^;\r\n]+)", ms[-1], re.I) or re.search(r'filename="?([^";\r\n]+)"?', ms[-1], re.I)
        if m:
            name = up.unquote(m.group(1).strip().strip('"'))
except Exception:
    pass
if not name:
    path = up.unquote(up.urlparse(url).path)
    name = path.rstrip('/').split('/')[-1]
name = re.sub(r'[^A-Za-z0-9._-]+', '_', name).strip('._') or 'app'
if not name.lower().endswith('.ipa'):
    name += '.ipa'
print(name)
PYN
)"
  if ! python3 - "$tmp" <<'PYN'
import sys, zipfile
try:
    z = zipfile.ZipFile(sys.argv[1])
    ok = any(n.startswith('Payload/') and n.endswith('.app/Info.plist') for n in z.namelist())
except Exception:
    ok = False
sys.exit(0 if ok else 1)
PYN
  then
    echo "ERROR: the link did not give a real IPA file (it may be a web page, not a direct download link)."
    exit 1
  fi
  mv "$tmp" "$WORK/in/$name"
  echo "== Saved as: $name"
}

mkdir -p "$WORK/in"
if [[ -n "$DIRECT_URL" ]]; then
  download_direct "$DIRECT_URL"
else
  echo "== Downloading ALL IPAs from $FROM_TAG"
  if [[ -n "$LINK_FILE" ]]; then
    PATTERN="$LINK_FILE"
  elif [[ -z "$GAME" || "$GAME" == "all" ]]; then
    PATTERN="*.ipa"
  else
    PATTERN="*${GAME}*.ipa"
  fi
  echo "== Pattern: $PATTERN"
  if ! gh release download "$FROM_TAG" -R "${SRC_REPO:-$REPO}" -p "$PATTERN" -D "$WORK/in"; then
    if [[ -n "$SRC_REPO" ]]; then
      echo "== gh download failed, trying direct download"
      download_direct "$IPA_LINK"
    else
      exit 1
    fi
  fi
fi

# Names already present in the target release (so old games are not redone)
EXISTING="$WORK/existing.txt"
: > "$EXISTING"
if [[ "$SKIP_EXISTING" == "true" && "$GAME" == "all" ]]; then
  gh release view "$TO_TAG" -R "$REPO" --json assets -q '.assets[].name' >"$EXISTING" 2>/dev/null || true
fi

MAP="$WORK/map.tsv"   # input IPA name <TAB> name inside the TO_TAG release (used for ashte.json)
: > "$MAP"

for ipa in "$WORK"/in/*.ipa; do
  fname="$(basename "$ipa")"
  if grep -Fxq "$fname" "$EXISTING"; then
    echo "== Skipping (already in $TO_TAG): $fname"
    printf '%s\t%s\n' "$fname" "$fname" >> "$MAP"
    continue
  fi
  echo "=========================================="
  echo "== Processing: $fname"
  T="$WORK/tmp"
  rm -rf "$T"
  mkdir -p "$T"
  unzip -q "$ipa" -d "$T"
  APP="$(ls -d "$T"/Payload/*.app | head -n1)"

  # 0) Build a clean output file name (game name instead of long hash names)
  CLEAN="$(python3 - "$APP/Info.plist" "$fname" "$NEW_NAME" <<'PY'
import plistlib, sys, re
path, fname, new_name = sys.argv[1:4]
n = ''
try:
    with open(path, 'rb') as f:
        d = plistlib.load(f)
    n = d.get('CFBundleDisplayName') or d.get('CFBundleName') or ''
except Exception:
    pass
if not n or new_name not in ('', 'keep', 'My App'):
    n = re.sub(r'\.ipa$', '', fname, flags=re.I)
    n = re.sub(r'^[0-9a-f]{32}_', '', n)
    n = re.sub(r'^ashte_', '', n)
    n = re.sub(r'\.signed$', '', n)
    n = re.sub(r'_\d+_com.*$', '', n)
n = re.sub(r'[^A-Za-z0-9._-]+', '_', n).strip('._') or 'app'
print(n + '.ipa')
PY
)"
  echo "== Output name: $CLEAN"
  if grep -Fxq "$CLEAN" "$EXISTING"; then
    echo "== Skipping (already in $TO_TAG): $CLEAN"
    printf '%s\t%s\n' "$fname" "$CLEAN" >> "$MAP"
    continue
  fi

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

  # 2) Patch embedded base64 icons & plain text titles inside ANY dylib or framework binary
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

# Same-length replacement so Mach-O offsets never move (UTF-8 and UTF-16LE variants)
def same_len(old_str, new_title, enc):
    o = old_str.encode(enc)
    unit = 2 if enc == 'utf-16-le' else 1
    t = new_title.encode(enc)[:len(o)]
    t = t + (' '.encode(enc)) * ((len(o) - len(t)) // unit)
    return o, t

NAME_VARIANTS = ("Check0ver Team", "CHECK0VER TEAM", "Check0ver team", "Checkover Team")

for root, _, names in os.walk(app):
    for n in names:
        p = os.path.join(root, n)
        if os.path.islink(p) or not os.path.isfile(p):
            continue
        low = n.lower()
        if not (n.endswith(".dylib") or 'igamegod' in low or 'check0ver' in low or 'checkover' in low):
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
        for variant in NAME_VARIANTS:
            for enc in ('utf-8', 'utf-16-le'):
                o, r = same_len(variant, title, enc)
                if o in new:
                    new = bytearray(bytes(new).replace(o, r))
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

  # 3) Place libashte.dylib inside Frameworks/ so ESign/Scarlet always signs it properly
  mkdir -p "$APP/Frameworks"
  cp "$WORK/libashte.dylib" "$APP/Frameworks/libashte.dylib"
  resize "$MENU_ICON" 120 120 "$APP/ashte_menu_icon.png"

  # 4) Inject @executable_path/Frameworks/libashte.dylib into all slices of mod dylibs & main executable
  python3 - "$APP" <<'PY'
import os, sys, plistlib, lief

app = sys.argv[1]
with open(os.path.join(app, "Info.plist"), "rb") as f:
    main_exe = plistlib.load(f).get("CFBundleExecutable", "")

targets = []
for root, _, names in os.walk(app):
    for n in names:
        if n in ("libashte.dylib", "CydiaSubstrate.dylib", "libsubstitute.dylib"):
            continue
        if n.endswith(".dylib") or n == "iGameGod":
            targets.append(os.path.join(root, n))

main_path = os.path.join(app, main_exe)
if os.path.isfile(main_path) and main_path not in targets:
    targets.append(main_path)

for t in targets:
    rel = os.path.relpath(t, app)
    try:
        fat = lief.MachO.parse(t)
        if fat:
            for b in fat:
                if any(getattr(l, "name", "") == "@executable_path/Frameworks/libashte.dylib" for l in b.libraries):
                    continue
                b.add_library("@executable_path/Frameworks/libashte.dylib")
            fat.write(t)
            print(f"  Injected @executable_path/Frameworks/libashte.dylib -> {rel}")
    except Exception as e:
        print(f"  Skipped {rel}: {e}")
PY

  # 5) Re-pack IPA with the clean name
  (cd "$T" && zip -qry "$WORK/out/$CLEAN" Payload)
  printf '%s\t%s\n' "$fname" "$CLEAN" >> "$MAP"
done

echo "== Uploading all rebranded IPAs to $TO_TAG"
gh release view "$TO_TAG" -R "$REPO" >/dev/null 2>&1 || \
  gh release create "$TO_TAG" -R "$REPO" -t "$TO_TAG" -n "Rebranded IPAs"
shopt -s nullglob
OUT_FILES=("$WORK"/out/*.ipa)
if [[ ${#OUT_FILES[@]} -eq 0 ]]; then
  echo "Nothing new to upload."
else
  gh release upload "$TO_TAG" "${OUT_FILES[@]}" -R "$REPO" --clobber
fi

# ---------------------------------------------------------------
# Build / update ashte.json (AltStore-style source) + img/ + imgg/
# ---------------------------------------------------------------
gh release view "$TO_TAG" -R "$REPO" --json assets > "$WORK/assets.json" 2>/dev/null \
  || echo '{"assets":[]}' > "$WORK/assets.json"

cat > "$WORK/make_source.py" <<'PYSRC'
import os, sys, json, re, zipfile, plistlib, hashlib, difflib, datetime
import urllib.request, urllib.parse

WORK = os.environ["WORK"]
REPO = os.environ["REPO"]
TAG = os.environ["TO_TAG"]
BRANCH = os.environ.get("BRANCH", "main")
OUT_JSON = os.environ.get("SOURCE_FILE", "ashte.json")
RAW = "https://raw.githubusercontent.com/%s/%s" % (REPO, BRANCH)
REL = "https://github.com/%s/releases/download/%s" % (REPO, urllib.parse.quote(TAG))
UA = {"User-Agent": "Mozilla/5.0"}
NOW = datetime.datetime.now(datetime.timezone.utc).strftime("%Y-%m-%dT%H:%M:%S+00:00")

DEFAULTS = {
    "name": "Ashtemobile",
    "subtitle": "A source for all of my apps & games",
    "description": "Welcome to my source! Here you'll find all of my apps.",
    "iconURL": "https://ashtemobile.site/logo.png",
    "website": "https://ashtemobile.site/",
    "patreonURL": "https://ashtemobile.site/Ashtemobile.json",
    "tintColor": "#ff007f",
    "featuredApps": [],
    "headerURL": "https://ashtemobile.site/logo.png",
}


def fetch(url, timeout=40):
    try:
        req = urllib.request.Request(url, headers=UA)
        with urllib.request.urlopen(req, timeout=timeout) as r:
            return r.read()
    except Exception as e:
        print("  fetch failed: %s (%s)" % (url, e))
        return None


def fetch_json(url):
    b = fetch(url)
    if not b:
        return None
    try:
        return json.loads(b.decode("utf-8"))
    except Exception:
        return None


def save(path, url):
    b = fetch(url)
    if not b:
        return False
    with open(path, "wb") as f:
        f.write(b)
    return True


def norm(s):
    return re.sub(r"[^a-z0-9]", "", (s or "").lower())


def appstore(bundle, name):
    """Look the app up in the App Store: by bundle id first, then by (similar) name."""
    j = fetch_json("https://itunes.apple.com/lookup?bundleId=%s&country=us&entity=software"
                   % urllib.parse.quote(bundle))
    if j and j.get("resultCount"):
        return j["results"][0]
    if name:
        j = fetch_json("https://itunes.apple.com/search?term=%s&country=us&entity=software&limit=5"
                       % urllib.parse.quote(name))
        best, score = None, 0.0
        for r in (j or {}).get("results", []):
            s = difflib.SequenceMatcher(None, norm(name), norm(r.get("trackName"))).ratio()
            if s > score:
                best, score = r, s
        if best and score >= 0.8:
            return best
    return None


def read_info(path):
    try:
        with zipfile.ZipFile(path) as z:
            for n in z.namelist():
                if re.match(r"^Payload/[^/]+\.app/Info\.plist$", n):
                    return plistlib.loads(z.read(n))
    except Exception as e:
        print("  cannot read Info.plist from %s (%s)" % (path, e))
    return {}


os.makedirs("img", exist_ok=True)
os.makedirs("imgg", exist_ok=True)

data = {}
if os.path.isfile(OUT_JSON):
    try:
        with open(OUT_JSON, encoding="utf-8") as f:
            data = json.load(f)
    except Exception:
        data = {}
for k, v in DEFAULTS.items():
    data.setdefault(k, v)

apps = data.get("apps") or []
by_bundle = {a.get("bundleIdentifier"): a for a in apps if a.get("bundleIdentifier")}

sizes = {}
try:
    with open(os.path.join(WORK, "assets.json"), encoding="utf-8") as f:
        for a in json.load(f).get("assets", []):
            sizes[a["name"]] = a.get("size")
except Exception:
    pass

pairs = []
with open(os.path.join(WORK, "map.tsv"), encoding="utf-8") as f:
    for line in f:
        line = line.rstrip("\n")
        if "\t" in line:
            pairs.append(tuple(line.split("\t", 1)))

for fname, out in pairs:
    print("== JSON: %s" % out)
    info = read_info(os.path.join(WORK, "in", fname))
    bundle = info.get("CFBundleIdentifier")
    if not bundle:
        print("  no bundle id, skipped")
        continue

    size = sizes.get(out)
    if not size:
        p = os.path.join(WORK, "out", out)
        size = os.path.getsize(p) if os.path.isfile(p) else None
    if not size:
        print("  not found in release %s, skipped" % TAG)
        continue

    plist_name = info.get("CFBundleDisplayName") or info.get("CFBundleName") or out[:-4]
    version = str(info.get("CFBundleShortVersionString") or info.get("CFBundleVersion") or "1.0")
    build = info.get("CFBundleVersion")
    min_os = str(info.get("MinimumOSVersion") or "15.0")
    slug = re.sub(r"[^a-z0-9]", "", out[:-4].lower()) or hashlib.md5(bundle.encode()).hexdigest()[:8]
    dl = "%s/%s" % (REL, urllib.parse.quote(out))

    old = by_bundle.get(bundle) or {}

    # ---- does this app still miss something? then ask the App Store
    icon_rel = old.get("icon") or ""
    if icon_rel and not os.path.isfile(icon_rel):
        icon_rel = ""
    shots = list(old.get("screenshotURLs") or [])
    desc = old.get("localizedDescription") or ""
    store = None
    if not (icon_rel and shots and desc):
        store = appstore(bundle, plist_name)
        print("  App Store: %s" % ((store or {}).get("trackName") or "not found"))

    # ---- icon -> img/
    if not icon_rel and store and store.get("artworkUrl512"):
        u = store["artworkUrl512"]
        ext = os.path.splitext(urllib.parse.urlparse(u).path)[1] or ".jpg"
        rel = "img/%s%s" % (slug, ext)
        if os.path.isfile(rel) or save(rel, u):
            icon_rel = rel

    # ---- iPhone screenshots -> imgg/
    if not shots and store:
        urls = store.get("screenshotUrls") or store.get("ipadScreenshotUrls") or []
        for i, u in enumerate(urls[:5], 1):
            ext = os.path.splitext(urllib.parse.urlparse(u).path)[1] or ".png"
            rel = "imgg/%s_screen_%d%s" % (slug, i, ext)
            if os.path.isfile(rel) or save(rel, u):
                shots.append("%s/%s" % (RAW, rel))

    # ---- genres -> description
    genres = [g for g in ((store or {}).get("genres") or []) if g]
    if not desc and genres:
        desc = "Genre: " + ", ".join(genres)

    is_game = bool(store) and ("Games" in genres or store.get("primaryGenreName") == "Games")
    typ = old.get("type") or ("games" if is_game else "apps")

    date = NOW
    for v in old.get("versions") or []:
        if v.get("version") == version and v.get("date"):
            date = v["date"]

    icon_url = ("%s/%s" % (RAW, icon_rel)) if icon_rel else data["iconURL"]
    app_id = old.get("id") or (store or {}).get("trackId") or int(hashlib.md5(bundle.encode()).hexdigest()[:8], 16)

    entry = {
        "id": app_id,
        "name": old.get("name") or (store or {}).get("trackName") or plist_name,
        "version": version,
        "size": size,
        "icon": icon_rel,
        "badge": old.get("badge", ""),
        "type": typ,
        "install_url": dl,
        "download_url": dl,
        "bundleIdentifier": bundle,
        "marketplaceID": old.get("marketplaceID", ""),
        "developerName": old.get("developerName") or "AshteMobile",
        "subtitle": old.get("subtitle") or "Awesome App",
        "localizedDescription": desc,
        "iconURL": icon_url,
        "tintColor": old.get("tintColor") or "#04ecfc",
        "category": old.get("category") or typ,
        "screenshotURLs": shots,
        "screenshots": shots,
        "versions": [{
            "version": version,
            "date": date,
            "localizedDescription": None,
            "downloadURL": dl,
            "size": size,
            "buildVersion": build,
            "minOSVersion": min_os,
            "screenshots": shots,
        }],
    }
    by_bundle[bundle] = entry

data["apps"] = sorted(by_bundle.values(), key=lambda a: (a.get("name") or "").lower())
with open(OUT_JSON, "w", encoding="utf-8") as f:
    json.dump(data, f, indent=4, ensure_ascii=False)
    f.write("\n")
print("== %s written: %d app(s)" % (OUT_JSON, len(data["apps"])))
PYSRC

echo "== Building ashte.json"
WORK="$WORK" REPO="$REPO" TO_TAG="$TO_TAG" BRANCH="${BRANCH:-main}" SOURCE_FILE="${SOURCE_FILE:-ashte.json}" \
  python3 "$WORK/make_source.py" || echo "WARNING: ashte.json step failed (IPAs were uploaded normally)"

rm -rf "$WORK/tmp"
echo "Done."
