// WebKit renders and receives input directly in the SDL window. No frame stream.
#import <AppKit/AppKit.h>
#import <WebKit/WebKit.h>
#include <SDL2/SDL.h>
#include <SDL2/SDL_syswm.h>
#include <string.h>

static void (*wake_ui)(void);
static unsigned changes;
static int find_result = -1;
static NSString *reader_text;
static char last_error[256];
static BOOL private_mode;
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
@end
@implementation OpalWebView
- (BOOL)performKeyEquivalent:(NSEvent *)event {
    if ((event.modifierFlags & NSEventModifierFlagCommand) != 0) {
        NSString *key = event.charactersIgnoringModifiers.lowercaseString;
        unsigned flag = [key isEqual:@"l"] ? 2 : [key isEqual:@"f"] ? 4 : [key isEqual:@"k"] ? 8 : 0;
        if (flag) { [self.window makeFirstResponder:self.superview]; changed(flag); return YES; }
        if ([key isEqual:@"r"]) { [self reload]; return YES; }
        if ([key isEqual:@"["]) { [self goBack]; return YES; }
        if ([key isEqual:@"]"]) { [self goForward]; return YES; }
    }
    return [super performKeyEquivalent:event];
}
@end
@interface OpalBrowserDelegate : NSObject <WKNavigationDelegate, WKUIDelegate, WKDownloadDelegate>
@end
static OpalWebView *view;
static OpalBrowserDelegate *delegate;
static NSMutableSet<WKDownload *> *downloads;
@implementation OpalBrowserDelegate
- (void)observeValueForKeyPath:(NSString *)keyPath ofObject:(id)object change:(NSDictionary *)change context:(void *)context { changed(1); }
- (WKWebView *)webView:(WKWebView *)webView createWebViewWithConfiguration:(WKWebViewConfiguration *)configuration forNavigationAction:(WKNavigationAction *)action windowFeatures:(WKWindowFeatures *)features {
    if (!action.targetFrame) [webView loadRequest:action.request];
    return nil;
}
- (void)webView:(WKWebView *)webView decidePolicyForNavigationAction:(WKNavigationAction *)action decisionHandler:(void (^)(WKNavigationActionPolicy))handler {
    NSString *scheme = action.request.URL.scheme.lowercaseString;
    BOOL safe = [scheme isEqual:@"http"] || [scheme isEqual:@"https"] || [scheme isEqual:@"blob"] || [action.request.URL.absoluteString isEqual:@"about:blank"];
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
- (void)webView:(WKWebView *)webView didStartProvisionalNavigation:(WKNavigation *)navigation { last_error[0] = 0; changed(1); }
- (void)webView:(WKWebView *)webView didFinishNavigation:(WKNavigation *)navigation { changed(1); }
- (void)webView:(WKWebView *)webView didFailProvisionalNavigation:(WKNavigation *)navigation withError:(NSError *)error {
    if (error.code != NSURLErrorCancelled) { copy_text(error.localizedDescription, last_error, sizeof(last_error)); changed(1); }
}
- (void)webView:(WKWebView *)webView didFailNavigation:(WKNavigation *)navigation withError:(NSError *)error { [self webView:webView didFailProvisionalNavigation:navigation withError:error]; }
- (void)webViewWebContentProcessDidTerminate:(WKWebView *)webView { strcpy(last_error, "Page stopped responding. Reload to try again."); changed(1); }
@end
void opal_browser_close(void) {
    ++lifetime;
    wake_ui = NULL;
    for (WKDownload *download in [downloads copy]) { download.delegate = nil; [download cancel:nil]; }
    downloads = nil;
    if (view) {
        [view stopLoading];
        for (NSString *key in @[@"URL", @"title", @"loading"]) [view removeObserver:delegate forKeyPath:key];
        view.navigationDelegate = nil; view.UIDelegate = nil;
        [view removeFromSuperview];
    }
    view = nil; delegate = nil; reader_text = nil; changes = 0; last_error[0] = 0; find_result = -1;
}
int opal_browser_attach(void *sdl_window, int incognito, void (*wake)(void)) {
    SDL_SysWMinfo info; SDL_VERSION(&info.version);
    if (!sdl_window || !SDL_GetWindowWMInfo(sdl_window, &info)) return 0;
    NSWindow *window = info.info.cocoa.window;
    if (!window) return 0;
    if (view && private_mode != (BOOL)incognito) opal_browser_close();
    wake_ui = wake;
    if (!view) {
        private_mode = incognito;
        WKWebViewConfiguration *config = [WKWebViewConfiguration new];
        config.websiteDataStore = incognito ? WKWebsiteDataStore.nonPersistentDataStore : WKWebsiteDataStore.defaultDataStore;
        view = [[OpalWebView alloc] initWithFrame:NSZeroRect configuration:config];
        delegate = [OpalBrowserDelegate new];
        view.navigationDelegate = delegate; view.UIDelegate = delegate;
        view.allowsBackForwardNavigationGestures = YES;
        for (NSString *key in @[@"URL", @"title", @"loading"]) [view addObserver:delegate forKeyPath:key options:0 context:NULL];
        [view loadHTMLString:@"<html><head><title>New page</title><meta name='color-scheme' content='dark light'></head><body></body></html>" baseURL:nil];
    }
    if (view.superview != window.contentView) [window.contentView addSubview:view];
    return 1;
}
void opal_browser_present(double x, double y, double width, double height, double pixel_w, double pixel_h, int visible, unsigned rgb, int dark) {
    if (!view) return;
    NSView *host = view.superview;
    NSRect bounds = host.bounds;
    if (pixel_w > 0 && pixel_h > 0) {
        double sx = bounds.size.width / pixel_w, sy = bounds.size.height / pixel_h;
        view.frame = NSMakeRect(bounds.origin.x + x * sx, bounds.origin.y + (host.isFlipped ? y : pixel_h - y - height) * sy, width * sx, height * sy);
    }
    view.appearance = [NSAppearance appearanceNamed:dark ? NSAppearanceNameDarkAqua : NSAppearanceNameAqua];
    if (@available(macOS 12.0, *)) view.underPageBackgroundColor = [NSColor colorWithRed:((rgb >> 16) & 255) / 255. green:((rgb >> 8) & 255) / 255. blue:(rgb & 255) / 255. alpha:1];
    if (!visible && !view.hidden && [view.window.firstResponder isKindOfClass:NSView.class] && [(NSView *)view.window.firstResponder isDescendantOf:view]) [view.window makeFirstResponder:host];
    view.hidden = !visible;
}
void opal_browser_navigate(const char *url) { NSURL *u = [NSURL URLWithString:[NSString stringWithUTF8String:url]]; if (u) [view loadRequest:[NSURLRequest requestWithURL:u]]; }
void opal_browser_command(int command) {
    if (command == 0) [view goBack]; else if (command == 1) [view goForward]; else if (command == 2) [view reload];
}
void opal_browser_zoom(double zoom) { view.pageZoom = zoom; }
void opal_browser_find(const char *text, int backwards) {
    WKFindConfiguration *config = [WKFindConfiguration new]; config.backwards = backwards; config.wraps = YES;
    unsigned generation = lifetime;
    [view findString:[NSString stringWithUTF8String:text] withConfiguration:config completionHandler:^(WKFindResult *result) { if (generation == lifetime) { find_result = result.matchFound ? 1 : 0; changed(16); } }];
}
void opal_browser_read(void) {
    unsigned generation = lifetime;
    [view evaluateJavaScript:@"document.body ? document.body.innerText : ''" completionHandler:^(id result, NSError *error) { if (generation == lifetime) { reader_text = !error && [result isKindOfClass:NSString.class] ? result : @""; changed(32); } }];
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
void opal_browser_test_pump(void) { [NSRunLoop.currentRunLoop runUntilDate:[NSDate dateWithTimeIntervalSinceNow:0.01]]; }
int opal_browser_test_attached(void) { return view && view.window && view.superview == view.window.contentView && view.frame.size.width > 0 && view.frame.size.height > 0; }

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
