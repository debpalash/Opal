// WebKit renders and receives input directly in the SDL window. No frame stream.
#import <AppKit/AppKit.h>
#import <WebKit/WebKit.h>
#import "browser_security.h"
extern int opal_browser_security_navigation_allowed(NSURL *);
extern void opal_browser_security_wait(WKWebView *, NSURLRequest *);
#include <SDL2/SDL.h>
#include <SDL2/SDL_syswm.h>
#include <string.h>

extern void opal_extensions_prepare(WKWebViewConfiguration *, int, void (*)(void));
extern void opal_extensions_bind(WKWebView *);
extern void opal_extensions_close(void);
extern void opal_extensions_navigation(WKWebView *);
extern void opal_extensions_forget(WKWebView *);
extern int opal_extensions_navigation_allowed(WKWebView *, NSURL *);
static void (*wake_ui)(void);
static unsigned changes;
static int find_result = -1;
static NSString *reader_text;
static char last_error[256];
static BOOL private_mode;
static SDL_Window *native_window;
static unsigned long long metadata_reads, presentation_writes;
static unsigned long long tabs_revision;
unsigned long long opal_browser_tabs_revision(void) { return tabs_revision; }
unsigned long long opal_browser_test_metadata_reads(void) { return metadata_reads; }
unsigned long long opal_browser_test_presentation_writes(void) { return presentation_writes; }
static unsigned lifetime;
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
@interface OpalWebView : WKWebView
@property(nonatomic) BOOL presentationThemeSet;
@property(nonatomic) BOOL presentationDark;
@property(nonatomic) unsigned presentationRGB;
@end
@implementation OpalWebView
- (BOOL)performKeyEquivalent:(NSEvent *)event {
    if ((event.modifierFlags & NSEventModifierFlagCommand) != 0) {
        NSString *key = event.charactersIgnoringModifiers.lowercaseString;
        if ([key isEqual:@"t"]) { changed(256); return YES; }
        if ([key isEqual:@"w"]) { changed(512); return YES; }
        unsigned flag = [key isEqual:@"l"] ? 2 : [key isEqual:@"f"] ? 4 : [key isEqual:@"k"] ? 8 : 0;
        if (flag) { [self.window makeFirstResponder:self.window.contentView]; changed(flag); return YES; }
        if ([key isEqual:@"r"]) { [self reload]; return YES; }
        if ([key isEqual:@"["]) { [self goBack]; return YES; }
        if ([key isEqual:@"]"]) { [self goForward]; return YES; }
    }
    if ((event.modifierFlags & NSEventModifierFlagControl) && [event.charactersIgnoringModifiers isEqual:@"\t"]) { changed((event.modifierFlags & NSEventModifierFlagShift) ? 2048 : 1024); return YES; }
    return [super performKeyEquivalent:event];
}
@end
@interface OpalBrowserDelegate : NSObject <WKNavigationDelegate, WKUIDelegate, WKDownloadDelegate>
@end
static OpalWebView *view;
int opal_browser_is_start_page(void) { return !view || !view.URL || [view.URL.absoluteString isEqual:@"about:blank"]; }
static NSMutableDictionary<NSNumber *, OpalWebView *> *tab_views;
static unsigned active_tab_id = 1;
static NSString *new_tab_url;
static NSView *clip_host;
static double cover_right;
static OpalBrowserDelegate *delegate;
static NSMutableSet<WKDownload *> *downloads;
static SDL_EventFilter previous_event_filter;
static void *previous_event_userdata;
static BOOL keyboard_filter_installed;
int opal_browser_has_focus(void);
static int browser_keyboard_filter(void *unused, SDL_Event *event) {
    // Cocoa's SDL field editor interprets keys before AppKit sends the same
    // NSEvent to WebKit. Native fields must have a single text-input owner.
    BOOL keyboard = event->type == SDL_KEYDOWN || event->type == SDL_KEYUP || event->type == SDL_TEXTINPUT || event->type == SDL_TEXTEDITING;
    if (keyboard && NSThread.isMainThread && native_window && (!event->key.windowID || event->key.windowID == SDL_GetWindowID(native_window)) && view && !view.hidden && opal_browser_has_focus()) {
        if (SDL_IsTextInputActive()) { SDL_StopTextInput(); if (wake_ui) wake_ui(); }
        return 0;
    }
    return previous_event_filter ? previous_event_filter(previous_event_userdata, event) : 1;
}
static void install_keyboard_filter(void) {
    if (keyboard_filter_installed) return;
    SDL_GetEventFilter(&previous_event_filter, &previous_event_userdata);
    SDL_SetEventFilter(browser_keyboard_filter, NULL);
    keyboard_filter_installed = YES;
}
static void remove_keyboard_filter(void) {
    if (!keyboard_filter_installed) return;
    SDL_EventFilter current = NULL; void *userdata = NULL;
    SDL_GetEventFilter(&current, &userdata);
    if (current == browser_keyboard_filter) SDL_SetEventFilter(previous_event_filter, previous_event_userdata);
    keyboard_filter_installed = NO;
}
@implementation OpalBrowserDelegate
- (void)observeValueForKeyPath:(NSString *)keyPath ofObject:(id)object change:(NSDictionary *)change context:(void *)context { ++tabs_revision; opal_extensions_navigation(object); changed(object == view ? 129 : 128); }
- (WKWebView *)webView:(WKWebView *)webView createWebViewWithConfiguration:(WKWebViewConfiguration *)configuration forNavigationAction:(WKNavigationAction *)action windowFeatures:(WKWindowFeatures *)features {
    if (!action.targetFrame) { new_tab_url = action.request.URL.absoluteString; changed(64); }
    return nil;
}
- (void)webView:(WKWebView *)webView decidePolicyForNavigationAction:(WKNavigationAction *)action decisionHandler:(void (^)(WKNavigationActionPolicy))handler {
    NSString *scheme = action.request.URL.scheme.lowercaseString;
    BOOL safe = [scheme isEqual:@"http"] || [scheme isEqual:@"https"] || [scheme isEqual:@"blob"] || [action.request.URL.absoluteString isEqual:@"about:blank"] || (!action.targetFrame.mainFrame && [action.request.URL.absoluteString isEqual:@"about:srcdoc"]);
    if (safe && [@[@"http", @"https"] containsObject:scheme] && !opal_browser_security_navigation_allowed(action.request.URL)) {
        if (action.targetFrame.mainFrame) { opal_browser_security_wait(webView, action.request); strcpy(last_error, "Page blocked by the selected privacy route or HTTPS-only setting."); changed(1); }
        handler(WKNavigationActionPolicyCancel); return;
    }
    int proxy_policy = safe ? opal_extensions_navigation_allowed(webView, action.request.URL) : 1;
    if (proxy_policy <= 0) {
        if (proxy_policy < 0) { strcpy(last_error, "Local and literal IPv6 pages require System proxy mode."); changed(1); }
        handler(WKNavigationActionPolicyCancel); return;
    }
    handler(!safe ? WKNavigationActionPolicyCancel : action.shouldPerformDownload ? WKNavigationActionPolicyDownload : WKNavigationActionPolicyAllow);
}
- (void)webView:(WKWebView *)webView decidePolicyForNavigationResponse:(WKNavigationResponse *)response decisionHandler:(void (^)(WKNavigationResponsePolicy))handler {
    handler(response.canShowMIMEType ? WKNavigationResponsePolicyAllow : WKNavigationResponsePolicyDownload);
}
- (void)webView:(WKWebView *)webView navigationAction:(WKNavigationAction *)action didBecomeDownload:(WKDownload *)download { download.delegate = self; if (!downloads) downloads = [NSMutableSet new]; [downloads addObject:download]; }
- (void)webView:(WKWebView *)webView navigationResponse:(WKNavigationResponse *)response didBecomeDownload:(WKDownload *)download { [self webView:webView navigationAction:nil didBecomeDownload:download]; }
- (void)download:(WKDownload *)download decideDestinationUsingResponse:(NSURLResponse *)response suggestedFilename:(NSString *)filename completionHandler:(void (^)(NSURL *))handler {
    NSSavePanel *panel = [NSSavePanel savePanel];
    panel.nameFieldStringValue = filename.lastPathComponent;
    unsigned generation = lifetime;
    [panel beginSheetModalForWindow:view.window completionHandler:^(NSModalResponse result) { handler(generation == lifetime && result == NSModalResponseOK ? panel.URL : nil); }];
}
- (void)downloadDidFinish:(WKDownload *)download { [downloads removeObject:download]; }
- (void)download:(WKDownload *)download didFailWithError:(NSError *)error resumeData:(NSData *)data {
    [downloads removeObject:download];
    if (error.code != NSURLErrorCancelled) { strcpy(last_error, "Download failed. Try again."); changed(1); }
}
- (void)webView:(WKWebView *)webView runJavaScriptAlertPanelWithMessage:(NSString *)message initiatedByFrame:(WKFrameInfo *)frame completionHandler:(void (^)(void))handler {
    NSAlert *alert = [NSAlert new]; alert.messageText = webView.URL.host ?: @"Website"; alert.informativeText = message;
    [alert beginSheetModalForWindow:webView.window completionHandler:^(NSModalResponse result) { handler(); }];
}
- (void)webView:(WKWebView *)webView runJavaScriptConfirmPanelWithMessage:(NSString *)message initiatedByFrame:(WKFrameInfo *)frame completionHandler:(void (^)(BOOL))handler {
    NSAlert *alert = [NSAlert new]; alert.messageText = webView.URL.host ?: @"Website"; alert.informativeText = message;
    [alert addButtonWithTitle:@"OK"]; [alert addButtonWithTitle:@"Cancel"];
    [alert beginSheetModalForWindow:webView.window completionHandler:^(NSModalResponse result) { handler(result == NSAlertFirstButtonReturn); }];
}
- (void)webView:(WKWebView *)webView didStartProvisionalNavigation:(WKNavigation *)navigation { if (webView == view) last_error[0] = 0; changed(webView == view ? 129 : 128); }
- (void)webView:(WKWebView *)webView didFinishNavigation:(WKNavigation *)navigation { changed(1); }
- (void)webView:(WKWebView *)webView didFailProvisionalNavigation:(WKNavigation *)navigation withError:(NSError *)error {
    if (webView == view && [error.domain isEqual:NSURLErrorDomain] && (error.code == NSURLErrorCannotConnectToHost || error.code == NSURLErrorNetworkConnectionLost || error.code == NSURLErrorTimedOut)) opal_security_route_failed();
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
    OpalWebView *tab = [[OpalWebView alloc] initWithFrame:view ? view.frame : NSZeroRect configuration:config];
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
    view.hidden = YES;
    if ([view.window.firstResponder isKindOfClass:NSView.class] && [(NSView *)view.window.firstResponder isDescendantOf:view]) [view.window makeFirstResponder:view.window.contentView];
    view = next; active_tab_id = identity; view.hidden = clip_host.hidden;
    last_error[0] = 0; reader_text = nil; find_result = -1;
    opal_extensions_bind(view); changed(129); return 1;
}
void opal_browser_tab_close(unsigned identity) {
    OpalWebView *tab = tab_views[@(identity)];
    if (!tab) return;
    if (tab == view) {
        if (tab_views.count == 1) return;
        for (NSNumber *key in tab_views) if (key.unsignedIntValue != identity) { opal_browser_tab_select(key.unsignedIntValue); break; }
    }
    opal_extensions_forget(tab); dispose_tab(tab); [tab_views removeObjectForKey:@(identity)]; ++tabs_revision; changed(128);
}
void opal_browser_tab_navigate(unsigned identity, const char *url) {
    NSURL *target = [NSURL URLWithString:[NSString stringWithUTF8String:url]];
    if (target) [tab_views[@(identity)] loadRequest:[NSURLRequest requestWithURL:target]];
}
int opal_browser_tab_info(unsigned identity, char *url, size_t url_cap, char *title, size_t title_cap, int *loading) {
    ++metadata_reads;
    OpalWebView *tab = tab_views[@(identity)]; if (!tab) return 0;
    copy_text(tab.URL.absoluteString ?: @"about:blank", url, url_cap); copy_text(tab.title ?: @"New tab", title, title_cap); *loading = tab.loading; return 1;
}
int opal_browser_tab_requested(char *url, size_t cap) {
    if (!new_tab_url) return 0;
    copy_text(new_tab_url, url, cap); new_tab_url = nil; return 1;
}
void opal_browser_close(void) {
    ++lifetime;
    remove_keyboard_filter();
    wake_ui = NULL;
    opal_extensions_close();
    for (WKDownload *download in [downloads copy]) { download.delegate = nil; [download cancel:nil]; }
    downloads = nil;
    for (OpalWebView *tab in tab_views.allValues) dispose_tab(tab);
    [clip_host removeFromSuperview]; clip_host = nil; cover_right = 0;
    tab_views = nil; active_tab_id = 1; new_tab_url = nil;
    ++tabs_revision;
    view = nil; delegate = nil; reader_text = nil; changes = 0; last_error[0] = 0; find_result = -1;
    native_window = NULL;
}
int opal_browser_attach(void *sdl_window, int incognito, void (*wake)(void)) {
    SDL_SysWMinfo info; SDL_VERSION(&info.version);
    if (!sdl_window || !SDL_GetWindowWMInfo(sdl_window, &info)) return 0;
    NSWindow *window = info.info.cocoa.window;
    if (!window) return 0;
    if (view && private_mode != (BOOL)incognito) opal_browser_close();
    wake_ui = wake;
    native_window = sdl_window;
    install_keyboard_filter();
    if (!view) {
        private_mode = incognito;
        WKWebViewConfiguration *config = [WKWebViewConfiguration new];
        config.websiteDataStore = incognito ? WKWebsiteDataStore.nonPersistentDataStore : WKWebsiteDataStore.defaultDataStore;
        NSInteger os = NSProcessInfo.processInfo.operatingSystemVersion.majorVersion;
        config.applicationNameForUserAgent = [NSString stringWithFormat:@"Version/%ld.0 Safari/605.1.15 Opal", (long)(os >= 26 ? os : os + 3)];
        opal_extensions_prepare(config, incognito, wake);
        tab_views = [NSMutableDictionary new]; active_tab_id = 1;
        delegate = [OpalBrowserDelegate new];
        view = create_tab(config, active_tab_id);
        opal_extensions_bind(view);
    }
    if (!clip_host) {
        clip_host = [[NSView alloc] initWithFrame:NSZeroRect];
        clip_host.wantsLayer = YES; clip_host.layer.masksToBounds = YES;
        [clip_host addSubview:view];
    }
    if (clip_host.superview != window.contentView) [window.contentView addSubview:clip_host];
    return 1;
}
void opal_browser_occlude_left(double right) { cover_right = right; }
void opal_browser_present(double x, double y, double width, double height, double pixel_w, double pixel_h, int visible, unsigned rgb, int dark) {
    if (!view) return;
    NSView *host = clip_host.superview;
    NSRect bounds = host.bounds;
    if (pixel_w > 0 && pixel_h > 0) {
        double sx = bounds.size.width / pixel_w, sy = bounds.size.height / pixel_h;
        double covered = MIN(width, MAX(0, cover_right - x)) * sx;
        NSRect clip_frame = NSMakeRect(bounds.origin.x + x * sx + covered, bounds.origin.y + (host.isFlipped ? y : pixel_h - y - height) * sy, width * sx - covered, height * sy);
        if (!NSEqualRects(clip_host.frame, clip_frame)) { ++presentation_writes; clip_host.frame = clip_frame; }
        // Crop beneath hover navigation without changing the page's viewport.
        NSRect page_frame = NSMakeRect(-covered, 0, width * sx, height * sy);
        if (!NSEqualRects(view.frame, page_frame)) { ++presentation_writes; view.frame = page_frame; }
    }
    if (!view.presentationThemeSet || view.presentationDark != (BOOL)dark || view.presentationRGB != rgb) {
        ++presentation_writes;
        view.appearance = [NSAppearance appearanceNamed:dark ? NSAppearanceNameDarkAqua : NSAppearanceNameAqua];
        if (@available(macOS 12.0, *)) view.underPageBackgroundColor = [NSColor colorWithRed:((rgb >> 16) & 255) / 255. green:((rgb >> 8) & 255) / 255. blue:(rgb & 255) / 255. alpha:1];
        view.presentationThemeSet = YES; view.presentationDark = dark; view.presentationRGB = rgb;
    }
    if (!visible && !view.hidden && [view.window.firstResponder isKindOfClass:NSView.class] && [(NSView *)view.window.firstResponder isDescendantOf:view]) [view.window makeFirstResponder:host];
    if (view.hidden != !visible) view.hidden = !visible;
    if (clip_host.hidden != !visible) clip_host.hidden = !visible;
}
double opal_browser_test_page_width(void) { return view.frame.size.width; }
double opal_browser_test_clip_width(void) { return clip_host.frame.size.width; }
void opal_browser_navigate(const char *url) { NSURL *u = [NSURL URLWithString:[NSString stringWithUTF8String:url]]; if (u) [view loadRequest:[NSURLRequest requestWithURL:u]]; }
void opal_browser_command(int command) {
    if (command == 0) [view goBack]; else if (command == 1) [view goForward]; else if (command == 2) [view reload];
}
void opal_browser_zoom(double zoom) { if (view && view.pageZoom != zoom) view.pageZoom = zoom; }
double opal_browser_zoom_factor(void) { return view ? view.pageZoom : 1; }
void opal_browser_find(const char *text, int backwards) {
    WKFindConfiguration *config = [WKFindConfiguration new]; config.backwards = backwards; config.wraps = YES;
    unsigned generation = lifetime; WKWebView *target = view;
    [view findString:[NSString stringWithUTF8String:text] withConfiguration:config completionHandler:^(WKFindResult *result) { if (generation == lifetime && target == view) { find_result = result.matchFound ? 1 : 0; changed(16); } }];
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
// Isolated native tests exercise the same WKWebView, not a mock browser.
void opal_browser_test_html(const char *html) { [view loadHTMLString:[NSString stringWithUTF8String:html] baseURL:[NSURL URLWithString:@"https://opal.invalid/"]]; }
void opal_browser_test_pump(void) { SDL_PumpEvents(); [NSRunLoop.currentRunLoop runUntilDate:[NSDate dateWithTimeIntervalSinceNow:0.01]]; }
void opal_browser_test_focus(void) { SDL_ShowWindow(native_window); SDL_RaiseWindow(native_window); [NSApp activateIgnoringOtherApps:YES]; [view.window makeKeyAndOrderFront:nil]; [view.window makeFirstResponder:view]; }
void opal_browser_test_key(const char *text, unsigned short code, int command, int repeat) {
    NSString *characters = [NSString stringWithUTF8String:text];
    for (int up = 0; up < 2; ++up) {
        NSEvent *event = [NSEvent keyEventWithType:up ? NSEventTypeKeyUp : NSEventTypeKeyDown location:NSZeroPoint modifierFlags:command ? NSEventModifierFlagCommand : 0 timestamp:NSProcessInfo.processInfo.systemUptime windowNumber:view.window.windowNumber context:nil characters:characters charactersIgnoringModifiers:characters isARepeat:repeat keyCode:code];
        // Bare test executables may not receive application activation. Route
        // their command equivalent through the same WebKit responder method.
        if (command && !view.window.isKeyWindow) { if (!up) [view performKeyEquivalent:event]; continue; }
        [NSApp postEvent:event atStart:NO];
        SDL_PumpEvents();
    }
}
int opal_browser_test_attached(void) { return view && view.window && view.superview == clip_host && clip_host.superview == view.window.contentView && view.frame.size.width > 0 && view.frame.size.height > 0; }

int opal_browser_has_focus(void) { return view && [view.window.firstResponder isKindOfClass:NSView.class] && [(NSView *)view.window.firstResponder isDescendantOf:view]; }
int opal_browser_test_visible(void) { return view && !view.hidden; }
static int snapshot_result;
void opal_browser_test_snapshot(const char *path) {
    snapshot_result = 0;
    NSString *file = [NSString stringWithUTF8String:path];
    [view takeSnapshotWithConfiguration:nil completionHandler:^(NSImage *image, NSError *error) {
        CGImageRef cg = [image CGImageForProposedRect:NULL context:nil hints:nil];
        if (error || !cg) { snapshot_result = -1; return; }
        NSData *png = [[[NSBitmapImageRep alloc] initWithCGImage:cg] representationUsingType:NSBitmapImageFileTypePNG properties:@{}];
        snapshot_result = [png writeToFile:file atomically:YES] ? 1 : -1;
    }];
}
int opal_browser_test_snapshot_result(void) { return snapshot_result; }
