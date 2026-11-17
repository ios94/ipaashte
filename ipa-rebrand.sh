#!/usr/bin/env bash
# ipa-rebrand.sh (Universal Frameworks Injection + Auto-Kill "Join ViP" + Blue Menu + Telegram Popup)

set -euo pipefail

REPO="${REPO:-USERNAME/REPO}"
FROM_TAG="${FROM_TAG:-V.1}"
TO_TAG="${TO_TAG:-V.5}"
NEW_NAME="${NEW_NAME:-keep}"
GAME="${GAME:-all}"                 # all = every game, or part of the IPA file name
SKIP_EXISTING="${SKIP_EXISTING:-true}"  # true = skip IPAs already uploaded to TO_TAG
IPA_LINK="${IPA_LINK:-}"             # optional: full release link of ONE ipa to process

LINK_FILE=""
if [[ -n "$IPA_LINK" ]]; then
  case "$IPA_LINK" in
    */releases/download/*/*.ipa) ;;
    *) echo "Bad link. Expected: https://github.com/OWNER/REPO/releases/download/TAG/File.ipa"; exit 1 ;;
  esac
  rest="${IPA_LINK#*/releases/download/}"
  FROM_TAG="$(python3 -c 'import sys,urllib.parse as u;print(u.unquote(sys.argv[1]))' "${rest%%/*}")"
  LINK_FILE="$(python3 -c 'import sys,urllib.parse as u;print(u.unquote(sys.argv[1]))' "${rest#*/}")"
  SKIP_EXISTING="false"
  echo "== Single IPA mode: tag=$FROM_TAG file=$LINK_FILE"
fi
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

# 1) Build the Universal Runtime Objective-C Hook Dylib (libashte.dylib)
cat > "$WORK/ashte_hook.m" <<EOF
#import <UIKit/UIKit.h>
#import <WebKit/WebKit.h>
#import <objc/runtime.h>

static NSString *const kNewTitle = @"${MENU_TITLE}";
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

// Heart button: it starts a web sign-in session (x.com). Skip it and open Telegram directly.
static const void *kSkipSessionKey = &kSkipSessionKey;
static BOOL isHeartLink(NSURL *url) {
    NSString *s = url.absoluteString.lowercaseString ?: @"";
    return [s containsString:@"iosgods"] || [s containsString:@"twitter"] || [s containsString:@"x.com"] ||
           [s containsString:@"facebook"] || [s containsString:@"youtube"] || [s containsString:@"t.me"];
}

static id (*orig_asInit)(id, SEL, NSURL *, NSString *, id) = NULL;
static id hooked_asInit(id self, SEL _cmd, NSURL *url, NSString *scheme, id handler) {
    id obj = orig_asInit(self, _cmd, url, scheme, handler);
    if (obj && isHeartLink(url)) objc_setAssociatedObject(obj, kSkipSessionKey, @YES, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    return obj;
}
static BOOL (*orig_asStart)(id, SEL) = NULL;
static BOOL hooked_asStart(id self, SEL _cmd) {
    if (objc_getAssociatedObject(self, kSkipSessionKey)) { openTelegramChannel(); return YES; }
    return orig_asStart(self, _cmd);
}

static id (*orig_sfaInit)(id, SEL, NSURL *, NSString *, id) = NULL;
static id hooked_sfaInit(id self, SEL _cmd, NSURL *url, NSString *scheme, id handler) {
    id obj = orig_sfaInit(self, _cmd, url, scheme, handler);
    if (obj && isHeartLink(url)) objc_setAssociatedObject(obj, kSkipSessionKey, @YES, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    return obj;
}
static BOOL (*orig_sfaStart)(id, SEL) = NULL;
static BOOL hooked_sfaStart(id self, SEL _cmd) {
    if (objc_getAssociatedObject(self, kSkipSessionKey)) { openTelegramChannel(); return YES; }
    return orig_sfaStart(self, _cmd);
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

    // 3. Change Labels ("Made for iOSGods.com" -> Ashte Mod)
    if ([view isKindOfClass:[UILabel class]]) {
        UILabel *lbl = (UILabel *)view;
        NSString *txt = lbl.text ?: lbl.attributedText.string;
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

        SEL selAuthInit = NSSelectorFromString(@"initWithURL:callbackURLScheme:completionHandler:");
        SEL selStart = NSSelectorFromString(@"start");
        Class asCls = NSClassFromString(@"ASWebAuthenticationSession");
        if (asCls) {
            Method mi = class_getInstanceMethod(asCls, selAuthInit);
            if (mi) { orig_asInit = (void *)method_getImplementation(mi); method_setImplementation(mi, (IMP)hooked_asInit); }
            Method ms = class_getInstanceMethod(asCls, selStart);
            if (ms) { orig_asStart = (void *)method_getImplementation(ms); method_setImplementation(ms, (IMP)hooked_asStart); }
        }
        Class sfaCls = NSClassFromString(@"SFAuthenticationSession");
        if (sfaCls) {
            Method mi2 = class_getInstanceMethod(sfaCls, selAuthInit);
            if (mi2) { orig_sfaInit = (void *)method_getImplementation(mi2); method_setImplementation(mi2, (IMP)hooked_sfaInit); }
            Method ms2 = class_getInstanceMethod(sfaCls, selStart);
            if (ms2) { orig_sfaStart = (void *)method_getImplementation(ms2); method_setImplementation(ms2, (IMP)hooked_sfaStart); }
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
  -framework QuartzCore -framework WebKit -framework AuthenticationServices \
  -install_name "@executable_path/Frameworks/libashte.dylib" \
  "$WORK/ashte_hook.m" -o "$WORK/libashte.dylib"

echo "== Downloading ALL IPAs from $FROM_TAG"
if [[ -n "$LINK_FILE" ]]; then
  PATTERN="$LINK_FILE"
elif [[ -z "$GAME" || "$GAME" == "all" ]]; then
  PATTERN="*.ipa"
else
  PATTERN="*${GAME}*.ipa"
fi
echo "== Pattern: $PATTERN"
gh release download "$FROM_TAG" -R "$REPO" -p "$PATTERN" -D "$WORK/in"

# Names already present in the target release (so old games are not redone)
EXISTING="$WORK/existing.txt"
: > "$EXISTING"
if [[ "$SKIP_EXISTING" == "true" && "$GAME" == "all" ]]; then
  gh release view "$TO_TAG" -R "$REPO" --json assets -q '.assets[].name' >"$EXISTING" 2>/dev/null || true
fi

for ipa in "$WORK"/in/*.ipa; do
  fname="$(basename "$ipa")"
  if grep -Fxq "$fname" "$EXISTING"; then
    echo "== Skipping (already in $TO_TAG): $fname"
    continue
  fi
  echo "=========================================="
  echo "== Processing: $fname"
  T="$WORK/tmp"
  rm -rf "$T"
  mkdir -p "$T"
  unzip -q "$ipa" -d "$T"
  APP="$(ls -d "$T"/Payload/*.app | head -n1)"

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
                b.add_library("@executable_path/Frameworks/libashte.dylib")
            fat.write(t)
            print(f"  Injected @executable_path/Frameworks/libashte.dylib -> {rel}")
    except Exception as e:
        print(f"  Skipped {rel}: {e}")
PY

  # 5) Re-pack IPA with its original filename
  (cd "$T" && zip -qry "$WORK/out/$fname" Payload)
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

rm -rf "$WORK/tmp"
echo "Done."
