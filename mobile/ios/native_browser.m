// iOS port of src/macos/native_browser.m: same opal_browser_* C API, UIKit + WKWebView.
// Views live in the SDL root view controller's view; the SDL window arg is ignored.
#import <UIKit/UIKit.h>
#import <WebKit/WebKit.h>
#import <QuartzCore/CAShapeLayer.h>
#include <string.h>

static void (*wake_ui)(void);
static unsigned changes;
static int find_result = -1;
static NSString *reader_text;
static char last_error[256];
static BOOL private_mode;
static unsigned long long tabs_revision;
static unsigned lifetime;
unsigned long long opal_browser_tabs_revision(void) { return tabs_revision; }
static void changed(unsigned flags) { changes |= flags; if (wake_ui) wake_ui(); }
static size_t copy_text(NSString *s, char *out, size_t cap) {
    if (!cap) return 0;
    NSData *data = [(s ?: @"") dataUsingEncoding:NSUTF8StringEncoding];
    size_t n = MIN(data.length, cap - 1);
    const unsigned char *p = data.bytes;
    if (n < data.length) while (n && (p[n] & 0xc0) == 0x80) --n;
    if (n) memcpy(out, p, n);
    out[n] = 0;
    return n;
}
static UIWindow *app_window(void) {
    for (UIScene *scene in UIApplication.sharedApplication.connectedScenes) {
        if (![scene isKindOfClass:UIWindowScene.class]) continue;
        for (UIWindow *window in ((UIWindowScene *)scene).windows) if (window.isKeyWindow) return window;
    }
    for (UIWindow *window in UIApplication.sharedApplication.windows) if (window.isKeyWindow) return window;
    return nil;
}
static UIViewController *presenter(void) {
    UIViewController *root = app_window().rootViewController;
    while (root.presentedViewController && !root.presentedViewController.isBeingDismissed) root = root.presentedViewController;
    return root;
}
@interface OpalWebView : WKWebView
@property(nonatomic) BOOL presentationThemeSet;
@property(nonatomic) BOOL presentationDark;
@property(nonatomic) unsigned presentationRGB;
@end
@implementation OpalWebView
@end
@interface OpalBrowserClipView : UIView
@property CGRect excludedRect;
@property CGRect maskBounds;
@end
@implementation OpalBrowserClipView
- (UIView *)hitTest:(CGPoint)point withEvent:(UIEvent *)event {
    if (!CGRectIsEmpty(self.excludedRect) && CGRectContainsPoint(self.excludedRect, point)) return nil;
    return [super hitTest:point withEvent:event];
}
@end
@interface OpalBrowserDelegate : NSObject <WKNavigationDelegate, WKUIDelegate, WKDownloadDelegate>
@end
static OpalWebView *view;
static NSMutableDictionary<NSNumber *, OpalWebView *> *tab_views;
static unsigned active_tab_id = 1;
static NSString *new_tab_url;
static OpalBrowserClipView *clip_host;
static double cover_right;
static OpalBrowserDelegate *delegate;
static NSMutableSet<WKDownload *> *downloads;

static BOOL has_first_responder(UIView *v) {
    if (v.isFirstResponder) return YES;
    for (UIView *s in v.subviews) if (has_first_responder(s)) return YES;
    return NO;
}
int opal_browser_is_start_page(void) { return !view || !view.URL || [view.URL.absoluteString isEqual:@"about:blank"]; }
int opal_browser_has_focus(void) { return view && has_first_responder(view); }

static void alert_panel(WKWebView *webView, NSString *message, BOOL cancel, void (^done)(BOOL)) {
    UIViewController *top = presenter();
    if (!top) { done(NO); return; }
    UIAlertController *a = [UIAlertController alertControllerWithTitle:webView.URL.host ?: @"Website" message:message preferredStyle:UIAlertControllerStyleAlert];
    if (cancel) [a addAction:[UIAlertAction actionWithTitle:@"Cancel" style:UIAlertActionStyleCancel handler:^(UIAlertAction *x) { done(NO); }]];
    [a addAction:[UIAlertAction actionWithTitle:@"OK" style:UIAlertActionStyleDefault handler:^(UIAlertAction *x) { done(YES); }]];
    [top presentViewController:a animated:YES completion:nil];
}
@implementation OpalBrowserDelegate
- (void)observeValueForKeyPath:(NSString *)keyPath ofObject:(id)object change:(NSDictionary *)change context:(void *)context { ++tabs_revision; changed(object == view ? 129 : 128); }
- (WKWebView *)webView:(WKWebView *)webView createWebViewWithConfiguration:(WKWebViewConfiguration *)configuration forNavigationAction:(WKNavigationAction *)action windowFeatures:(WKWindowFeatures *)features {
    if (!action.targetFrame) { new_tab_url = action.request.URL.absoluteString; changed(64); }
    return nil;
}
- (void)webView:(WKWebView *)webView decidePolicyForNavigationAction:(WKNavigationAction *)action decisionHandler:(void (^)(WKNavigationActionPolicy))handler {
    NSString *scheme = action.request.URL.scheme.lowercaseString;
    BOOL safe = [scheme isEqual:@"http"] || [scheme isEqual:@"https"] || [scheme isEqual:@"blob"] || [action.request.URL.absoluteString isEqual:@"about:blank"] || (!action.targetFrame.mainFrame && [action.request.URL.absoluteString isEqual:@"about:srcdoc"]);
    handler(!safe ? WKNavigationActionPolicyCancel : action.shouldPerformDownload ? WKNavigationActionPolicyDownload : WKNavigationActionPolicyAllow);
}
- (void)webView:(WKWebView *)webView decidePolicyForNavigationResponse:(WKNavigationResponse *)response decisionHandler:(void (^)(WKNavigationResponsePolicy))handler {
    handler(response.canShowMIMEType ? WKNavigationResponsePolicyAllow : WKNavigationResponsePolicyDownload);
}
- (void)webView:(WKWebView *)webView navigationAction:(WKNavigationAction *)action didBecomeDownload:(WKDownload *)download { download.delegate = self; if (!downloads) downloads = [NSMutableSet new]; [downloads addObject:download]; }
- (void)webView:(WKWebView *)webView navigationResponse:(WKNavigationResponse *)response didBecomeDownload:(WKDownload *)download { [self webView:webView navigationAction:nil didBecomeDownload:download]; }
- (void)download:(WKDownload *)download decideDestinationUsingResponse:(NSURLResponse *)response suggestedFilename:(NSString *)filename completionHandler:(void (^)(NSURL *))handler {
    NSURL *dir = [NSFileManager.defaultManager URLsForDirectory:NSDocumentDirectory inDomains:NSUserDomainMask].firstObject;
    NSURL *dest = [dir URLByAppendingPathComponent:filename.lastPathComponent.length ? filename.lastPathComponent : @"download"];
    [NSFileManager.defaultManager removeItemAtURL:dest error:nil];
    handler(dest);
}
- (void)downloadDidFinish:(WKDownload *)download { [downloads removeObject:download]; }
- (void)download:(WKDownload *)download didFailWithError:(NSError *)error resumeData:(NSData *)data {
    [downloads removeObject:download];
    if (error.code != NSURLErrorCancelled) { strcpy(last_error, "Download failed. Try again."); changed(1); }
}
- (void)webView:(WKWebView *)webView runJavaScriptAlertPanelWithMessage:(NSString *)message initiatedByFrame:(WKFrameInfo *)frame completionHandler:(void (^)(void))handler {
    alert_panel(webView, message, NO, ^(BOOL ok) { handler(); });
}
- (void)webView:(WKWebView *)webView runJavaScriptConfirmPanelWithMessage:(NSString *)message initiatedByFrame:(WKFrameInfo *)frame completionHandler:(void (^)(BOOL))handler {
    alert_panel(webView, message, YES, handler);
}
- (void)webView:(WKWebView *)webView didStartProvisionalNavigation:(WKNavigation *)navigation { if (webView == view) last_error[0] = 0; changed(webView == view ? 129 : 128); }
- (void)webView:(WKWebView *)webView didFinishNavigation:(WKNavigation *)navigation { changed(1); }
- (void)webView:(WKWebView *)webView didFailProvisionalNavigation:(WKNavigation *)navigation withError:(NSError *)error {
    if (webView == view && error.code != NSURLErrorCancelled) { copy_text(error.localizedDescription, last_error, sizeof(last_error)); changed(1); }
}
- (void)webView:(WKWebView *)webView didFailNavigation:(WKNavigation *)navigation withError:(NSError *)error { [self webView:webView didFailProvisionalNavigation:navigation withError:error]; }
- (void)webViewWebContentProcessDidTerminate:(WKWebView *)webView { strcpy(last_error, "Page stopped responding. Reload to try again."); changed(1); }
@end
static void dispose_tab(OpalWebView *tab) {
    [tab stopLoading];
    for (NSString *key in @[@"URL", @"title", @"loading"]) [tab removeObserver:delegate forKeyPath:key];
    tab.navigationDelegate = nil; tab.UIDelegate = nil;
    [tab removeFromSuperview];
}
static OpalWebView *create_tab(WKWebViewConfiguration *config, unsigned identity) {
    OpalWebView *tab = [[OpalWebView alloc] initWithFrame:view ? view.frame : CGRectZero configuration:config];
    tab.navigationDelegate = delegate; tab.UIDelegate = delegate;
    tab.allowsBackForwardNavigationGestures = YES; tab.hidden = YES;
    for (NSString *key in @[@"URL", @"title", @"loading"]) [tab addObserver:delegate forKeyPath:key options:0 context:NULL];
    tab_views[@(identity)] = tab;
    ++tabs_revision;
    if (clip_host) [clip_host addSubview:tab];
    [tab loadHTMLString:@"<html><head><title>New tab</title><meta name='color-scheme' content='dark light'></head><body></body></html>" baseURL:nil];
    return tab;
}
int opal_browser_tab_select(unsigned identity) {
    if (!view || identity == 0) return 0;
    if (active_tab_id == identity) return 1;
    OpalWebView *next = tab_views[@(identity)];
    if (!next) {
        if (tab_views.count >= 32) return 0;
        next = create_tab([view.configuration copy], identity);
    }
    next.frame = view.frame;
    view.hidden = YES;
    [view endEditing:YES];
    view = next; active_tab_id = identity; view.hidden = clip_host.hidden;
    last_error[0] = 0; reader_text = nil; find_result = -1;
    changed(129); return 1;
}
void opal_browser_tab_close(unsigned identity) {
    OpalWebView *tab = tab_views[@(identity)];
    if (!tab) return;
    if (tab == view) {
        if (tab_views.count == 1) return;
        for (NSNumber *key in tab_views) if (key.unsignedIntValue != identity) { opal_browser_tab_select(key.unsignedIntValue); break; }
    }
    dispose_tab(tab); [tab_views removeObjectForKey:@(identity)]; ++tabs_revision; changed(128);
}
void opal_browser_tab_navigate(unsigned identity, const char *url) {
    NSURL *target = [NSURL URLWithString:[NSString stringWithUTF8String:url]];
    if (target) [tab_views[@(identity)] loadRequest:[NSURLRequest requestWithURL:target]];
}
int opal_browser_tab_info(unsigned identity, char *url, size_t url_cap, char *title, size_t title_cap, int *loading) {
    OpalWebView *tab = tab_views[@(identity)]; if (!tab) return 0;
    copy_text(tab.URL.absoluteString ?: @"about:blank", url, url_cap); copy_text(tab.title ?: @"New tab", title, title_cap); *loading = tab.loading; return 1;
}
int opal_browser_tab_requested(char *url, size_t cap) {
    if (!new_tab_url) return 0;
    copy_text(new_tab_url, url, cap); new_tab_url = nil; return 1;
}
void opal_browser_close(void) {
    ++lifetime;
    wake_ui = NULL;
    for (WKDownload *download in [downloads copy]) { download.delegate = nil; [download cancel:nil]; }
    downloads = nil;
    for (OpalWebView *tab in tab_views.allValues) dispose_tab(tab);
    [clip_host removeFromSuperview]; clip_host = nil; cover_right = 0;
    tab_views = nil; active_tab_id = 1; new_tab_url = nil;
    ++tabs_revision;
    view = nil; delegate = nil; reader_text = nil; changes = 0; last_error[0] = 0; find_result = -1;
}
int opal_browser_attach(void *unused_window, int incognito, void (*wake)(void)) {
    UIView *host = app_window().rootViewController.view;
    if (!host) return 0;
    if (view && private_mode != (BOOL)incognito) opal_browser_close();
    wake_ui = wake;
    if (!view) {
        private_mode = incognito;
        WKWebViewConfiguration *config = [WKWebViewConfiguration new];
        config.websiteDataStore = incognito ? WKWebsiteDataStore.nonPersistentDataStore : WKWebsiteDataStore.defaultDataStore;
        config.allowsInlineMediaPlayback = YES;
        config.applicationNameForUserAgent = @"Opal";
        tab_views = [NSMutableDictionary new]; active_tab_id = 1;
        delegate = [OpalBrowserDelegate new];
        view = create_tab(config, active_tab_id);
    }
    if (!clip_host) {
        clip_host = [[OpalBrowserClipView alloc] initWithFrame:CGRectZero];
        clip_host.clipsToBounds = YES;
        [clip_host addSubview:view];
    }
    if (clip_host.superview != host) [host addSubview:clip_host];
    return 1;
}
void opal_browser_occlude_left(double right) { cover_right = right; }
void opal_browser_present(double x, double y, double width, double height, double pixel_w, double pixel_h, int visible, unsigned rgb, int dark) {
    if (!view) return;
    UIView *host = clip_host.superview;
    CGRect bounds = host.bounds;
    if (pixel_w > 0 && pixel_h > 0) {
        double sx = bounds.size.width / pixel_w, sy = bounds.size.height / pixel_h;
        double covered = MIN(width, MAX(0, cover_right - x)) * sx;
        CGRect clip_frame = CGRectMake(bounds.origin.x + x * sx + covered, bounds.origin.y + y * sy, width * sx - covered, height * sy);
        if (!CGRectEqualToRect(clip_host.frame, clip_frame)) clip_host.frame = clip_frame;
        CGRect page_frame = CGRectMake(-covered, 0, width * sx, height * sy);
        if (!CGRectEqualToRect(view.frame, page_frame)) view.frame = page_frame;
    }
    if (!view.presentationThemeSet || view.presentationDark != (BOOL)dark || view.presentationRGB != rgb) {
        view.overrideUserInterfaceStyle = dark ? UIUserInterfaceStyleDark : UIUserInterfaceStyleLight;
        UIColor *bg = [UIColor colorWithRed:((rgb >> 16) & 255) / 255. green:((rgb >> 8) & 255) / 255. blue:(rgb & 255) / 255. alpha:1];
        view.underPageBackgroundColor = bg;
        view.presentationThemeSet = YES; view.presentationDark = dark; view.presentationRGB = rgb;
    }
    if (!visible && !view.hidden) [view endEditing:YES];
    if (view.hidden != !visible) view.hidden = !visible;
    if (clip_host.hidden != !visible) clip_host.hidden = !visible;
}
void opal_browser_occlude_popup(double x, double y, double w, double h, double pixel_w, double pixel_h) {
    if (!clip_host || !clip_host.superview || pixel_w <= 0 || pixel_h <= 0) return;
    UIView *host = clip_host.superview; CGRect bounds = host.bounds;
    CGRect hole = CGRectZero;
    if (w > 0 && h > 0) {
        CGRect frame = CGRectMake(bounds.origin.x + x * bounds.size.width / pixel_w, bounds.origin.y + y * bounds.size.height / pixel_h, w * bounds.size.width / pixel_w, h * bounds.size.height / pixel_h);
        hole = [clip_host convertRect:frame fromView:host];
    }
    if (CGRectEqualToRect(hole, clip_host.excludedRect) && CGRectEqualToRect(clip_host.bounds, clip_host.maskBounds)) return;
    clip_host.excludedRect = hole; clip_host.maskBounds = clip_host.bounds;
    if (CGRectIsEmpty(hole)) { clip_host.layer.mask = nil; return; }
    CAShapeLayer *mask = [CAShapeLayer layer]; CGMutablePathRef path = CGPathCreateMutable();
    CGPathAddRect(path, NULL, clip_host.bounds); CGPathAddRoundedRect(path, NULL, hole, 8, 8);
    mask.path = path; mask.fillRule = kCAFillRuleEvenOdd; clip_host.layer.mask = mask; CGPathRelease(path);
}
void opal_browser_navigate(const char *url) { NSURL *u = [NSURL URLWithString:[NSString stringWithUTF8String:url]]; if (u) [view loadRequest:[NSURLRequest requestWithURL:u]]; }
void opal_browser_command(int command) {
    if (command == 0) [view goBack]; else if (command == 1) [view goForward]; else if (command == 2) [view reload];
}
void opal_browser_zoom(double zoom) { if (view && view.pageZoom != zoom) view.pageZoom = zoom; }
double opal_browser_zoom_factor(void) { return view ? view.pageZoom : 1; }
void opal_browser_find(const char *text, int backwards) {
    unsigned generation = lifetime; WKWebView *target = view;
    if (@available(iOS 16.0, *)) {
        WKFindConfiguration *config = [WKFindConfiguration new]; config.backwards = backwards; config.wraps = YES;
        [view findString:[NSString stringWithUTF8String:text] withConfiguration:config completionHandler:^(WKFindResult *result) { if (generation == lifetime && target == view) { find_result = result.matchFound ? 1 : 0; changed(16); } }];
    } else { find_result = 0; changed(16); }
}
void opal_browser_read(void) {
    unsigned generation = lifetime; WKWebView *target = view;
    [view evaluateJavaScript:@"document.body ? document.body.innerText : ''" completionHandler:^(id result, NSError *error) { if (generation == lifetime && target == view) { reader_text = !error && [result isKindOfClass:NSString.class] ? result : @""; changed(32); } }];
}
unsigned opal_browser_poll(char *url, size_t url_cap, char *title, size_t title_cap, char *error, size_t error_cap, int *loading, int *found) {
    unsigned flags = changes; changes = 0;
    copy_text(view.URL.absoluteString, url, url_cap); copy_text(view.title, title, title_cap);
    copy_text([NSString stringWithUTF8String:last_error], error, error_cap);
    *loading = view.loading; *found = find_result;
    return flags;
}
size_t opal_browser_reader(char *out, size_t cap) { return copy_text(reader_text, out, cap); }
void opal_browser_test_html(const char *html) { [view loadHTMLString:[NSString stringWithUTF8String:html] baseURL:[NSURL URLWithString:@"https://opal.invalid/"]]; }
void opal_browser_test_pump(void) { [NSRunLoop.currentRunLoop runUntilDate:[NSDate dateWithTimeIntervalSinceNow:0.01]]; }
int opal_browser_test_attached(void) { return view && view.window && view.superview == clip_host && clip_host.superview == view.window.rootViewController.view && view.frame.size.width > 0 && view.frame.size.height > 0; }

// Privacy/extension layer is macOS-only. These no-op stubs satisfy the shared
// browser_privacy.zig / browser_start.zig externs so they link; features read as unavailable.
int opal_extensions_supported(void) { return 0; }
int opal_extensions_ready(void) { return 0; }
unsigned opal_extensions_generation(void) { return 0; }
void opal_extensions_configure(const char *json, const char *script, int reload) {}
void opal_extensions_security_configure(const char *script) {}
void opal_security_tick(const char *directory, int tor) {}
void opal_security_shutdown(void) {}
void opal_security_stats(int private_, unsigned long long *bytes, unsigned long long *ads, unsigned long long *trackers, unsigned long long *cookies) { *bytes = *ads = *trackers = *cookies = 0; }
void opal_security_reset_stats(int private_) {}
int opal_security_tor_status(void) { return 0; }
int opal_security_tor_pid(void) { return 0; }
int opal_security_test_tor_listener(void) { return 0; }
int opal_security_rules_ready(void) { return 0; }
int opal_security_tor_progress(void) { return 0; }
int opal_security_tor_port(void) { return 0; }
size_t opal_security_tor_message(char *out, size_t cap) { if (cap) out[0] = 0; return 0; }
void opal_security_tor_retry(void) {}
void opal_security_pool_scan(void) {}
int opal_security_pool_health(int index) { return 0; }
int opal_security_pool_count(void) { return 0; }
int opal_security_pool_selected(void) { return -1; }
void opal_security_pool_rotate(void) {}
void opal_security_test_pool_lease(int index, double seconds) {}
void opal_extension_load(int slot, const char *path) {}
void opal_extension_unload(int slot) {}
int opal_extension_status(int slot, char *name, size_t name_cap, char *message, size_t cap) { if (name_cap) name[0] = 0; if (cap) message[0] = 0; return 0; }
void opal_extension_action(int slot, int options) {}
void opal_extension_action_at(int slot, double x, double y, double w, double h) {}
unsigned long long opal_extension_icon_revision(void) { return 0; }
size_t opal_extension_icon_copy(int slot, unsigned char *out, size_t cap) { return 0; }
void opal_extension_pick(void) {}
size_t opal_extension_take_error(char *out, size_t cap) { if (cap) out[0] = 0; return 0; }
int opal_browser_proxy_supported(void) { return 0; }
size_t opal_extension_take_import(char *path, size_t cap, char *name, size_t name_cap) { return 0; }
void opal_extensions_test_eval(const char *js) {}
int opal_extensions_test_result(char *out, size_t cap) { if (cap) out[0] = 0; return 0; }
