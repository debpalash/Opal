// WebKit extensions and browser-only network/privacy settings. Main thread only.
#import <AppKit/AppKit.h>
#import <WebKit/WebKit.h>
#import <Network/Network.h>
#include <string.h>
#include <CommonCrypto/CommonDigest.h>
static __weak WKWebView *page;
static void (*wake)(void);
static NSDictionary *settings;
static NSString *canvas_source;
static unsigned generation;
static BOOL incognito;
static WKWebExtensionController *controller;
static NSMutableDictionary<NSNumber *, WKWebExtensionContext *> *contexts;
static NSMutableDictionary<NSNumber *, NSNumber *> *statuses;
static NSMutableDictionary<NSNumber *, NSString *> *names;
static NSMutableDictionary<NSNumber *, NSString *> *messages;
static void signal_ui(void);
static NSString *import_error;
static unsigned serials[8];
static WKContentRuleList *proxy_guard;
static BOOL proxy_guard_compiling;
static NSMapTable<WKWebView *, NSURL *> *waiting_proxy_urls;
static void wait_for_proxy(WKWebView *web, NSURL *url) {
    if (!web || !url) return;
    if (!waiting_proxy_urls) waiting_proxy_urls = [NSMapTable weakToStrongObjectsMapTable];
    [waiting_proxy_urls setObject:url forKey:web];
}
static NSString * const local_pattern = @"^https?://(localhost|[^/]+\\.localhost|127\\.[0-9.]+|0\\.0\\.0\\.0|10\\.[0-9.]+|192\\.168\\.[0-9.]+|172\\.(1[6-9]|2[0-9]|3[01])\\.[0-9.]+|169\\.254\\.[0-9.]+|\\[[0-9a-f:.]*\\])([:/]|$)";
static BOOL proxy_selected(void) { NSString *mode = settings[@"proxy_mode"]; return mode && ![mode isEqual:@"system"]; }
static void apply_guard(WKUserContentController *content) {
    if (!proxy_guard) return;
    [content removeContentRuleList:proxy_guard];
    if (proxy_selected()) [content addContentRuleList:proxy_guard];
}
static void prepare_guard(void) {
    if (proxy_guard || proxy_guard_compiling) return;
    proxy_guard_compiling = YES;
    // WebKit content-blocker regexes do not support disjunction. Each
    // local-address pattern therefore has its own independently compiled rule.
    NSArray *patterns = @[@"localhost", @"[^/]+\\.localhost", @"[^/]+\\.local", @"127\\.[0-9.]+", @"0\\.0\\.0\\.0", @"10\\.[0-9.]+", @"192\\.168\\.[0-9.]+", @"172\\.1[6-9]\\.[0-9.]+", @"172\\.2[0-9]\\.[0-9.]+", @"172\\.3[01]\\.[0-9.]+", @"169\\.254\\.[0-9.]+", @"\\[[0-9a-f:.]+\\]"];
    NSMutableArray *rules = [NSMutableArray new];
    for (NSString *pattern in patterns) {
        NSString *filter = [NSString stringWithFormat:@"^https?://([^/@]*@)?%@\\.?[:/]", pattern];
        [rules addObject:@{@"trigger":@{@"url-filter":filter}, @"action":@{@"type":@"block"}}];
    }
    NSData *data = [NSJSONSerialization dataWithJSONObject:rules options:0 error:NULL];
    NSString *json = [[NSString alloc] initWithData:data encoding:NSUTF8StringEncoding];
    [WKContentRuleListStore.defaultStore compileContentRuleListForIdentifier:@"opal-browser-proxy-local-guard-v2" encodedContentRuleList:json completionHandler:^(WKContentRuleList *list, NSError *error) {
        proxy_guard_compiling = NO; proxy_guard = list;
        if (page) apply_guard(page.configuration.userContentController);
        if (error) { import_error = @"Could not prepare proxy protection. Select System proxy and try again."; signal_ui(); return; }
        NSMapTable *waiting = waiting_proxy_urls; waiting_proxy_urls = nil;
        for (WKWebView *web in waiting.keyEnumerator) {
            NSURL *url = [waiting objectForKey:web];
            if (url) [web loadRequest:[NSURLRequest requestWithURL:url]];
        }
    }];
}

static NSPanel *popup;
static NSPopover *action_popover;
static WKWebExtensionAction *presented_action;
static BOOL test_hide_popup;
static WKWebView *ready_probe;
static unsigned ready_generation, ready_serial;
static NSOpenPanel *picker;
static NSString *import_path;
static NSString *import_name;
static void signal_ui(void) { if (wake) wake(); }
static void status(int slot, int code, NSString *message) {
    statuses[@(slot)] = @(code); messages[@(slot)] = message ?: @""; signal_ui();
}
static size_t copy(NSString *text, char *out, size_t cap) {
    if (!cap) return 0;
    NSData *data = [(text ?: @"") dataUsingEncoding:NSUTF8StringEncoding];
    size_t n = MIN(cap - 1, data.length); const unsigned char *p = data.bytes;
    if (n < data.length) while (n && (p[n] & 0xc0) == 0x80) --n;
    if (n) memcpy(out, p, n); out[n] = 0; return n;
}
@interface OpalExtensionHost : NSObject <WKWebExtensionControllerDelegate, WKWebExtensionWindow, WKWebExtensionTab, WKNavigationDelegate>
@end
static OpalExtensionHost *host;
@interface OpalBrowserTab : NSObject <WKWebExtensionTab>
@property(nonatomic, weak) WKWebView *web;
@end
static NSMutableArray<OpalBrowserTab *> *browser_tabs;
static OpalBrowserTab *current_tab;
@implementation OpalBrowserTab
- (id<WKWebExtensionWindow>)windowForWebExtensionContext:(WKWebExtensionContext *)context { return host; }
- (NSUInteger)indexInWindowForWebExtensionContext:(WKWebExtensionContext *)context { return [browser_tabs indexOfObject:self]; }
- (WKWebView *)webViewForWebExtensionContext:(WKWebExtensionContext *)context { return self.web; }
- (NSString *)titleForWebExtensionContext:(WKWebExtensionContext *)context { return self.web.title; }
- (NSURL *)urlForWebExtensionContext:(WKWebExtensionContext *)context { return self.web.URL; }
- (BOOL)isPrivateForWebExtensionContext:(WKWebExtensionContext *)context { return incognito; }
- (BOOL)isSelectedForWebExtensionContext:(WKWebExtensionContext *)context { return self == current_tab; }
- (BOOL)isLoadingCompleteForWebExtensionContext:(WKWebExtensionContext *)context { return !self.web.loading; }
- (CGSize)sizeForWebExtensionContext:(WKWebExtensionContext *)context { return self.web.bounds.size; }
- (double)zoomFactorForWebExtensionContext:(WKWebExtensionContext *)context { return self.web.pageZoom; }
- (void)setZoomFactor:(double)zoom forWebExtensionContext:(WKWebExtensionContext *)context completionHandler:(void (^)(NSError *))done { self.web.pageZoom = zoom; done(nil); }
- (void)reloadFromOrigin:(BOOL)origin forWebExtensionContext:(WKWebExtensionContext *)context completionHandler:(void (^)(NSError *))done { origin ? [self.web reloadFromOrigin] : [self.web reload]; done(nil); }
- (void)loadURL:(NSURL *)url forWebExtensionContext:(WKWebExtensionContext *)context completionHandler:(void (^)(NSError *))done {
    if ([url.scheme isEqual:@"http"] || [url.scheme isEqual:@"https"] || [url.absoluteString isEqual:@"about:blank"]) { [self.web loadRequest:[NSURLRequest requestWithURL:url]]; done(nil); }
    else done([NSError errorWithDomain:@"OpalBrowser" code:1 userInfo:nil]);
}
@end
static void show_popup(WKWebView *web, NSString *title) {
    if (!web || !page.window) return;
    [popup close];
    popup = [[NSPanel alloc] initWithContentRect:NSMakeRect(0, 0, 440, 600) styleMask:NSWindowStyleMaskTitled | NSWindowStyleMaskClosable | NSWindowStyleMaskResizable backing:NSBackingStoreBuffered defer:NO];
    popup.releasedWhenClosed = NO; popup.title = title ?: @"Extension";
    popup.contentView = web; [popup center]; if (!test_hide_popup) [popup makeKeyAndOrderFront:nil];
}
@implementation OpalExtensionHost
- (void)webView:(WKWebView *)webView didFinishNavigation:(WKNavigation *)navigation {
    if (webView != ready_probe) return;
    unsigned epoch = ready_generation, token = ready_serial;
    NSString *site = page.URL.absoluteString ?: @"https://example.org/";
    [webView callAsyncJavaScript:@"const u = new URL(site); return await browser.runtime.sendMessage({what:'popupPanelData', hostname:u.hostname, origin:u.origin});" arguments:@{@"site":site} inFrame:nil inContentWorld:WKContentWorld.pageWorld completionHandler:^(id result, NSError *error) {
        if (epoch != generation || token != serials[0]) return;
        ready_probe.navigationDelegate = nil; ready_probe = nil;
        if (error || ![result isKindOfClass:NSDictionary.class]) status(0, -1, @"uBlock Origin Lite could not finish starting. Reload the extension.");
        else { status(0, 2, @"Enabled"); if (page.URL) [page reload]; }
    }];
}
- (NSArray *)webExtensionController:(WKWebExtensionController *)c openWindowsForExtensionContext:(WKWebExtensionContext *)context { return page ? @[self] : @[]; }
- (id<WKWebExtensionWindow>)webExtensionController:(WKWebExtensionController *)c focusedWindowForExtensionContext:(WKWebExtensionContext *)context { return page ? self : nil; }
- (NSArray *)tabsForWebExtensionContext:(WKWebExtensionContext *)context { return browser_tabs.copy ?: @[]; }
- (id<WKWebExtensionTab>)activeTabForWebExtensionContext:(WKWebExtensionContext *)context { return current_tab; }
- (id<WKWebExtensionWindow>)windowForWebExtensionContext:(WKWebExtensionContext *)context { return self; }
- (NSUInteger)indexInWindowForWebExtensionContext:(WKWebExtensionContext *)context { return 0; }
- (WKWebView *)webViewForWebExtensionContext:(WKWebExtensionContext *)context { return page; }
- (NSString *)titleForWebExtensionContext:(WKWebExtensionContext *)context { return page.title; }
- (NSURL *)urlForWebExtensionContext:(WKWebExtensionContext *)context { return page.URL; }
- (BOOL)isPrivateForWebExtensionContext:(WKWebExtensionContext *)context { return incognito; }
- (BOOL)isSelectedForWebExtensionContext:(WKWebExtensionContext *)context { return YES; }
- (BOOL)isLoadingCompleteForWebExtensionContext:(WKWebExtensionContext *)context { return !page.loading; }
- (CGSize)sizeForWebExtensionContext:(WKWebExtensionContext *)context { return page.bounds.size; }
- (double)zoomFactorForWebExtensionContext:(WKWebExtensionContext *)context { return page.pageZoom; }
- (void)setZoomFactor:(double)zoom forWebExtensionContext:(WKWebExtensionContext *)context completionHandler:(void (^)(NSError *))done { page.pageZoom = zoom; done(nil); }
- (void)reloadFromOrigin:(BOOL)origin forWebExtensionContext:(WKWebExtensionContext *)context completionHandler:(void (^)(NSError *))done { origin ? [page reloadFromOrigin] : [page reload]; done(nil); }
- (void)loadURL:(NSURL *)url forWebExtensionContext:(WKWebExtensionContext *)context completionHandler:(void (^)(NSError *))done {
    if ([url.scheme isEqual:@"http"] || [url.scheme isEqual:@"https"]) { [page loadRequest:[NSURLRequest requestWithURL:url]]; done(nil); }
    else done([NSError errorWithDomain:@"OpalBrowser" code:1 userInfo:@{NSLocalizedDescriptionKey:@"Only web URLs are supported"}]);
}
- (void)webExtensionController:(WKWebExtensionController *)c openOptionsPageForExtensionContext:(WKWebExtensionContext *)context completionHandler:(void (^)(NSError *))done {
    if (!context.optionsPageURL) { done(nil); return; }
    WKWebViewConfiguration *config = context.webViewConfiguration;
    WKWebView *web = [[WKWebView alloc] initWithFrame:NSMakeRect(0, 0, 900, 700) configuration:config];
    [web loadRequest:[NSURLRequest requestWithURL:context.optionsPageURL]]; show_popup(web, context.webExtension.displayName); [popup setContentSize:NSMakeSize(900, 700)]; done(nil);
}
- (void)webExtensionController:(WKWebExtensionController *)c presentPopupForAction:(WKWebExtensionAction *)action forExtensionContext:(WKWebExtensionContext *)context completionHandler:(void (^)(NSError *))done {
    if (!page.window || (page.hidden && !test_hide_popup)) {
        done([NSError errorWithDomain:@"OpalBrowser" code:2 userInfo:@{NSLocalizedDescriptionKey:@"Open the browser page to use extension controls."}]);
        return;
    }
    if (presented_action == action && action_popover.shown) {
        [action_popover close]; action_popover = nil; presented_action = nil;
        done(nil); return;
    }
    [action_popover close];
    if (presented_action != action) [presented_action closePopup];
    action_popover = action.popupPopover; presented_action = action;
    if (!action_popover) { done([NSError errorWithDomain:@"OpalBrowser" code:3 userInfo:nil]); return; }
    action_popover.behavior = NSPopoverBehaviorTransient;
    action_popover.contentViewController.view.appearance = page.appearance;
    if (!test_hide_popup) {
        NSRect bounds = page.bounds;
        CGFloat y = page.isFlipped ? NSMinY(bounds) : NSMaxY(bounds) - 1;
        NSRect anchor = NSMakeRect(MAX(NSMinX(bounds), NSMaxX(bounds) - 220), y, 1, 1);
        [action_popover showRelativeToRect:anchor ofView:page preferredEdge:NSRectEdgeMinY];
    }
    done(nil);
}
// A later optional permission always requires an explicit native choice.
- (void)webExtensionController:(WKWebExtensionController *)c promptForPermissions:(NSSet *)permissions inTab:(id<WKWebExtensionTab>)tab forExtensionContext:(WKWebExtensionContext *)context completionHandler:(void (^)(NSSet<WKWebExtensionPermission> *, NSDate * _Nullable))done {
    NSAlert *alert = [NSAlert new]; alert.messageText = context.webExtension.displayName ?: @"Extension permissions";
    alert.informativeText = [NSString stringWithFormat:@"Allow these additional permissions?\n%@", [[permissions allObjects] componentsJoinedByString:@", "]];
    [alert addButtonWithTitle:@"Allow"]; [alert addButtonWithTitle:@"Cancel"];
    [alert beginSheetModalForWindow:page.window completionHandler:^(NSModalResponse result) { done(result == NSAlertFirstButtonReturn ? permissions : [NSSet set], nil); }];
}
@end
int opal_extensions_supported(void) { if (@available(macOS 15.4, *)) return 1; return 0; }
unsigned opal_extensions_generation(void) { return generation; }
static void apply_proxy(WKWebsiteDataStore *store) {
    if (!settings) return;
    if (@available(macOS 14.0, *)) {
        NSString *mode = settings[@"proxy_mode"];
        if ([mode isEqual:@"system"]) store.proxyConfigurations = nil;
            else {
            NSArray *profiles = settings[@"profiles"];
            NSUInteger index = [settings[@"active_profile"] unsignedIntegerValue];
            if (index >= profiles.count) return; // Validated before committing preferences.
            NSDictionary *profile = profiles[index]; NSString *host_name = profile[@"host"];
            if ([host_name hasPrefix:@"["] && [host_name hasSuffix:@"]"]) host_name = [host_name substringWithRange:NSMakeRange(1, host_name.length - 2)];
            nw_endpoint_t endpoint = nw_endpoint_create_host(host_name.UTF8String, [profile[@"port"] stringValue].UTF8String);
            NSString *kind = profile[@"kind"];
            nw_proxy_config_t proxy = [kind isEqual:@"socks5"] ? nw_proxy_config_create_socksv5(endpoint) : nw_proxy_config_create_http_connect(endpoint, [kind isEqual:@"https"] ? nw_tls_create_options() : nil);
            nw_proxy_config_clear_excluded_domains(proxy);
            nw_proxy_config_add_match_domain(proxy, "");
            nw_proxy_config_set_failover_allowed(proxy, false);
            NSString *username = profile[@"username"], *password = profile[@"password"];
            if (username.length) nw_proxy_config_set_username_and_password(proxy, username.UTF8String, password.UTF8String);
            store.proxyConfigurations = @[proxy];
        }
    }
}
static void apply_settings(BOOL network) {
    if (!page || !settings) return;
    WKUserContentController *content = page.configuration.userContentController;
    apply_guard(content);
    [content removeAllUserScripts];
    if ([settings[@"canvas"] boolValue] && canvas_source) {
        NSArray *exceptions = [settings[@"canvas_exceptions"] isKindOfClass:NSArray.class] ? settings[@"canvas_exceptions"] : @[];
        NSData *data = [NSJSONSerialization dataWithJSONObject:exceptions options:0 error:NULL];
        NSString *json = [[NSString alloc] initWithData:data encoding:NSUTF8StringEncoding] ?: @"[]";
        NSString *script = [canvas_source stringByReplacingOccurrencesOfString:@"__OPAL_EXCEPTIONS__" withString:json];
        [content addUserScript:[[WKUserScript alloc] initWithSource:script injectionTime:WKUserScriptInjectionTimeAtDocumentStart forMainFrameOnly:NO]];
    }
    if (network) apply_proxy(page.configuration.websiteDataStore);
}
void opal_extensions_configure(const char *json, const char *script, int reload) {
    NSData *data = [[NSString stringWithUTF8String:json] dataUsingEncoding:NSUTF8StringEncoding];
    NSDictionary *decoded = [NSJSONSerialization JSONObjectWithData:data options:0 error:NULL];
    if (![decoded isKindOfClass:NSDictionary.class]) return;
    settings = decoded; canvas_source = [NSString stringWithUTF8String:script];
    prepare_guard();
    if (page && proxy_selected() && !proxy_guard) {
        wait_for_proxy(page, page.URL);
        [page stopLoading]; [page loadHTMLString:@"<title>Preparing proxy protection</title>" baseURL:nil];
    }
    apply_settings(YES); if (reload && page.URL) { [page stopLoading]; [page reload]; }
}
void opal_extensions_prepare(WKWebViewConfiguration *config, int is_private, void (*notify)(void)) {
    ++generation; incognito = is_private; wake = notify;
    apply_proxy(config.websiteDataStore);
    apply_guard(config.userContentController);
    if (@available(macOS 15.4, *)) {
        WKWebExtensionControllerConfiguration *cfg = incognito ? WKWebExtensionControllerConfiguration.nonPersistentConfiguration : [WKWebExtensionControllerConfiguration configurationWithIdentifier:[[NSUUID alloc] initWithUUIDString:@"B0AC309D-8B3E-41D3-A449-29C7E7C00A16"]];
        cfg.defaultWebsiteDataStore = config.websiteDataStore;
        controller = [[WKWebExtensionController alloc] initWithConfiguration:cfg];
        host = [OpalExtensionHost new]; controller.delegate = host; config.webExtensionController = controller;
        contexts = [NSMutableDictionary new]; statuses = [NSMutableDictionary new]; names = [NSMutableDictionary new]; messages = [NSMutableDictionary new];
    }
}
static OpalBrowserTab *tab_for(WKWebView *web) {
    for (OpalBrowserTab *tab in browser_tabs) if (tab.web == web) return tab;
    return nil;
}
void opal_extensions_bind(WKWebView *web) {
    BOOL first = browser_tabs == nil;
    if (first) browser_tabs = [NSMutableArray new];
    OpalBrowserTab *tab = tab_for(web);
    BOOL opened = tab == nil;
    if (!tab) { tab = [OpalBrowserTab new]; tab.web = web; [browser_tabs addObject:tab]; }
    OpalBrowserTab *previous = current_tab;
    if (page != web) { [action_popover close]; [presented_action closePopup]; action_popover = nil; presented_action = nil; }
    page = web; current_tab = tab; apply_settings(NO);
    if (@available(macOS 15.4, *)) {
        if (first) [controller didOpenWindow:host];
        if (opened) [controller didOpenTab:tab];
        if (!previous || previous != tab) {
            [controller didActivateTab:tab previousActiveTab:previous];
        }
        [controller didFocusWindow:host];
    }
}
void opal_extensions_navigation(WKWebView *web) {
    if (@available(macOS 15.4, *)) {
        OpalBrowserTab *tab = tab_for(web);
        if (tab) [controller didChangeTabProperties:WKWebExtensionTabChangedPropertiesURL | WKWebExtensionTabChangedPropertiesTitle | WKWebExtensionTabChangedPropertiesLoading forTab:tab];
    }
}
void opal_extensions_forget(WKWebView *web) {
    OpalBrowserTab *tab = tab_for(web);
    if (!tab) return;
    if (@available(macOS 15.4, *)) [controller didCloseTab:tab windowIsClosing:NO];
    [browser_tabs removeObject:tab];
    if (tab == current_tab) { current_tab = nil; page = nil; }
}
void opal_extensions_close(void) {
    ++generation; wake = NULL;
    [action_popover close]; [presented_action closePopup];
    action_popover = nil; presented_action = nil;
    if (@available(macOS 15.4, *)) for (WKWebExtensionContext *context in contexts.allValues) [controller unloadExtensionContext:context error:NULL];
    for (int i = 0; i < 8; ++i) ++serials[i];
    ready_probe.navigationDelegate = nil; [ready_probe stopLoading]; ready_probe = nil;
    [popup close]; popup = nil;
    [picker cancel:nil]; picker = nil; import_path = nil; import_name = nil;
    waiting_proxy_urls = nil;
    browser_tabs = nil; current_tab = nil; page = nil; controller = nil; host = nil; contexts = nil; statuses = nil; names = nil; messages = nil;
}
int opal_extensions_ready(void) { return page != nil; }
void opal_extension_load(int slot, const char *path) {
    if (slot < 0 || slot >= 8) return;
    if (@available(macOS 15.4, *)) {
        if (!controller || !page) return;
        WKWebExtensionContext *previous = contexts[@(slot)];
        if (previous) [controller unloadExtensionContext:previous error:NULL];
        [contexts removeObjectForKey:@(slot)];
        unsigned token = ++serials[slot], epoch = generation;
        status(slot, 1, @"Loading extension…");
        NSURL *url = [NSURL fileURLWithPath:[NSString stringWithUTF8String:path]];
        [WKWebExtension extensionWithResourceBaseURL:url completionHandler:^(WKWebExtension *extension, NSError *error) {
            if (epoch != generation || token != serials[slot]) return;
            if (!extension || extension.errors.count) { status(slot, -1, @"This extension is not compatible with WebKit."); return; }
            WKWebExtensionContext *context = [[WKWebExtensionContext alloc] initForExtension:extension];
            unsigned char digest[CC_SHA256_DIGEST_LENGTH];
            NSData *identity_data = [url.path dataUsingEncoding:NSUTF8StringEncoding];
            CC_SHA256(identity_data.bytes, (CC_LONG)identity_data.length, digest);
            NSMutableString *identity = [NSMutableString new];
            for (int i = 0; i < 16; ++i) [identity appendFormat:@"%02x", digest[i]];
            if (slot == 0) identity = [@"ubol" mutableCopy];
            context.uniqueIdentifier = [@"opal-" stringByAppendingString:identity];
            context.baseURL = [NSURL URLWithString:[NSString stringWithFormat:@"webkit-extension://opal-%@/", identity]];
            context.hasAccessToPrivateData = incognito;
            for (NSString *permission in extension.requestedPermissions) [context setPermissionStatus:WKWebExtensionContextPermissionStatusGrantedExplicitly forPermission:permission];
            for (WKWebExtensionMatchPattern *pattern in extension.requestedPermissionMatchPatterns) [context setPermissionStatus:WKWebExtensionContextPermissionStatusGrantedExplicitly forMatchPattern:pattern];
            NSError *load_error = nil;
            if (![controller loadExtensionContext:context error:&load_error]) { status(slot, -1, @"Extension could not start. Try another WebKit-compatible package."); return; }
            contexts[@(slot)] = context; names[@(slot)] = extension.displayName ?: @"Extension";
            if (extension.hasBackgroundContent) {
                [context loadBackgroundContentWithCompletionHandler:^(NSError *background_error) {
                    if (epoch != generation || token != serials[slot]) return;
                    if (background_error) { status(slot, -1, @"Extension background could not start."); }
                    else if (slot == 0) {
                        // The pinned official package answers only after its rule
                        // initialization completes; do not report enabled early.
                        ready_generation = epoch; ready_serial = token;
                        ready_probe = [[WKWebView alloc] initWithFrame:NSMakeRect(0, 0, 440, 600) configuration:context.webViewConfiguration];
                        ready_probe.navigationDelegate = host;
                        [ready_probe loadRequest:[NSURLRequest requestWithURL:[NSURL URLWithString:@"popup.html" relativeToURL:context.baseURL]]];
                        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, 20 * NSEC_PER_SEC), dispatch_get_main_queue(), ^{
                            if (epoch == generation && token == serials[0] && ready_probe) {
                                ready_probe.navigationDelegate = nil; [ready_probe stopLoading]; ready_probe = nil;
                                status(0, -1, @"uBlock Origin Lite is taking too long to start. Reload the extension.");
                            }
                        });
                    } else { status(slot, 2, @"Enabled"); if (page.URL) [page reload]; }
                }];
            } else status(slot, 2, @"Enabled");
        }];
    }
}
void opal_extension_unload(int slot) {
    if (slot < 0 || slot >= 8) return;
    ++serials[slot];
    [action_popover close]; [presented_action closePopup];
    action_popover = nil; presented_action = nil;
    if (slot == 0) { ready_probe.navigationDelegate = nil; [ready_probe stopLoading]; ready_probe = nil; }
    if (@available(macOS 15.4, *)) { WKWebExtensionContext *context = contexts[@(slot)]; if (context) [controller unloadExtensionContext:context error:NULL]; [contexts removeObjectForKey:@(slot)]; status(slot, 0, @"Disabled"); }
}
int opal_extension_status(int slot, char *name, size_t name_cap, char *message, size_t message_cap) {
    if (slot < 0 || slot >= 8) return -1;
    copy(names[@(slot)], name, name_cap); copy(messages[@(slot)], message, message_cap);
    return [statuses[@(slot)] intValue];
}
void opal_extension_action(int slot, int options) {
    if (@available(macOS 15.4, *)) { WKWebExtensionContext *context = contexts[@(slot)]; if (!context) return; if (options) [host webExtensionController:controller openOptionsPageForExtensionContext:context completionHandler:^(NSError *e) {}]; else [context performActionForTab:current_tab]; }
}
void opal_extension_pick(void) {
    if (@available(macOS 15.4, *)) {
        if (picker || !page.window) return;
        picker = NSOpenPanel.openPanel; picker.title = @"Add browser extension"; picker.message = @"Choose a WebKit-compatible extension ZIP or a folder containing manifest.json.";
        picker.canChooseDirectories = YES; picker.canChooseFiles = YES; picker.allowsMultipleSelection = NO;
        unsigned epoch = generation;
        [picker beginSheetModalForWindow:page.window completionHandler:^(NSModalResponse result) {
            NSURL *url = picker.URL; picker = nil;
            if (result != NSModalResponseOK || epoch != generation) return;
            [WKWebExtension extensionWithResourceBaseURL:url completionHandler:^(WKWebExtension *extension, NSError *error) {
                if (epoch != generation) return;
                if (!extension || extension.errors.count) { import_error = @"Choose an extension package compatible with WebKit."; signal_ui(); return; }
                NSAlert *alert = [NSAlert new]; alert.messageText = [NSString stringWithFormat:@"Add %@?", extension.displayName ?: @"extension"];
                alert.informativeText = [NSString stringWithFormat:@"Only add extensions you trust.\n\nPermissions: %@\n\nWebsite access: %@", [[extension.requestedPermissions allObjects] componentsJoinedByString:@", "], [[[extension.requestedPermissionMatchPatterns allObjects] valueForKey:@"string"] componentsJoinedByString:@", "]];
                [alert addButtonWithTitle:@"Add extension"]; [alert addButtonWithTitle:@"Cancel"];
                [alert beginSheetModalForWindow:page.window completionHandler:^(NSModalResponse answer) { if (epoch == generation && answer == NSAlertFirstButtonReturn) { import_path = url.path; import_name = extension.displayName ?: @"Extension"; signal_ui(); } }];
            }];
        }];
    }
}
size_t opal_extension_take_import(char *path, size_t cap, char *name, size_t name_cap) { size_t n = copy(import_path, path, cap); copy(import_name, name, name_cap); import_path = nil; import_name = nil; return n; }
// Test-only DOM probes use the production page and never enable a remote bridge.
static NSString *probe_result;
void opal_extensions_test_eval(const char *js) { probe_result = nil; [page evaluateJavaScript:[NSString stringWithUTF8String:js] completionHandler:^(id value, NSError *error) { probe_result = error ? @"ERROR" : [value description]; }]; }
int opal_extensions_test_result(char *out, size_t cap) { if (!probe_result) return 0; copy(probe_result, out, cap); return 1; }

size_t opal_extension_take_error(char *out, size_t cap) { size_t n = copy(import_error, out, cap); import_error = nil; return n; }
int opal_browser_proxy_supported(void) { if (@available(macOS 14.0, *)) return 1; return 0; }

int opal_extensions_navigation_allowed(WKWebView *web, NSURL *url) {
    if (!proxy_selected() || ![@[@"http", @"https"] containsObject:url.scheme.lowercaseString]) return 1;
    NSRegularExpression *regex = [NSRegularExpression regularExpressionWithPattern:local_pattern options:NSRegularExpressionCaseInsensitive error:NULL];
    NSString *hostname = url.host.lowercaseString;
    while ([hostname hasSuffix:@"."]) hostname = [hostname substringToIndex:hostname.length - 1];
    if ([hostname containsString:@":"] && ![hostname hasPrefix:@"["]) hostname = [NSString stringWithFormat:@"[%@]", hostname];
    NSString *canonical = [NSString stringWithFormat:@"%@://%@/", url.scheme, hostname];
    if ([hostname hasSuffix:@".local"] || [regex firstMatchInString:canonical options:0 range:NSMakeRange(0, canonical.length)]) return -1;
    if (!proxy_guard) { wait_for_proxy(web, url); prepare_guard(); return 0; }
    return 1;
}
int opal_browser_proxy_guard_ready(void) { return proxy_guard != nil; }
int opal_extensions_test_tab_count(void) { return (int)[host tabsForWebExtensionContext:nil].count; }

void opal_extension_test_hide_popup(int hide) { test_hide_popup = hide; }
int opal_extension_test_popup_size(double *width, double *height) {
    if (action_popover) {
        *width = action_popover.contentViewController.preferredContentSize.width;
        *height = action_popover.contentViewController.preferredContentSize.height;
    } else if (popup) {
        *width = popup.contentView.bounds.size.width;
        *height = popup.contentView.bounds.size.height;
    } else return 0;
    return *width > 0 && *height > 0;
}
