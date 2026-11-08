// Browser session measurements, tracking-cookie cleanup, Tor and verified exits.
// All shared state is confined to the main queue; network/process callbacks hop back.
#import <AppKit/AppKit.h>
#import "browser_security.h"
#import <Network/NSURLSession+Network.h>
#include <sys/socket.h>
#include <netinet/in.h>
#include <signal.h>
#include <unistd.h>

static NSDictionary *policy;
static NSString *measurement_script;
static void (*wake_ui)(void);
static unsigned revision = 1;
static unsigned long long counters[2][4]; // reported bytes, observed ads/trackers, removed cookies
static NSMutableDictionary<NSNumber *, WKContentRuleList *> *rule_lists;
static NSMutableSet<NSNumber *> *compiling;
static NSMapTable<WKUserContentController *, NSNumber *> *contents;
static NSArray *ad_domains, *tracker_domains;
static unsigned mask(void);
static void signal_change(void) { ++revision; if (wake_ui) wake_ui(); }
unsigned opal_security_revision(void) { return revision; }
int opal_security_rules_ready(void) { return mask() == 0 || rule_lists[@(mask())] != nil; }
void opal_security_stats(int private, unsigned long long *bytes, unsigned long long *ads, unsigned long long *trackers, unsigned long long *cookies) {
    unsigned long long *s = counters[private != 0]; *bytes = s[0]; *ads = s[1]; *trackers = s[2]; *cookies = s[3];
}
void opal_security_reset_stats(int private) { memset(counters[private != 0], 0, sizeof(counters[0])); if (wake_ui) wake_ui(); }
static unsigned mask(void) { return ([policy[@"block_ads"] boolValue] ? 1 : 0) | ([policy[@"block_trackers"] boolValue] ? 2 : 0); }
@interface OpalPrivacyMeasurements : NSObject <WKScriptMessageHandler, WKHTTPCookieStoreObserver>
@property BOOL private;
@property(nonatomic, weak) WKHTTPCookieStore *store;
@property NSMutableSet<NSString *> *deleting;
@end
static NSMapTable<WKHTTPCookieStore *, OpalPrivacyMeasurements *> *cookie_stores;
@implementation OpalPrivacyMeasurements
- (void)userContentController:(WKUserContentController *)content didReceiveScriptMessage:(WKScriptMessage *)message {
    if (![message.body isKindOfClass:NSDictionary.class] || ![@[@"http", @"https"] containsObject:message.frameInfo.request.URL.scheme.lowercaseString]) return;
    NSDictionary *d = message.body;
    NSArray *keys = @[@"bytes", @"ads", @"trackers"];
    BOOL rules_ready = mask() == 0 || rule_lists[@(mask())] != nil;
    for (unsigned i = 0; i < 3; ++i) {
        id n = d[keys[i]];
        if (![n isKindOfClass:NSNumber.class] || [n doubleValue] < 0 || [n doubleValue] > 1099511627776.) continue;
        if (i && !rules_ready) continue;
        counters[self.private][i] += [n unsignedLongLongValue];
    }
    // macOS 15's WebKit does not notify cookie-store observers for cookies a
    // page sets through document.cookie, so tracking cookies set by script
    // survived. Each page measurement also sweeps that page's cookie store.
    WKHTTPCookieStore *store = message.webView.configuration.websiteDataStore.httpCookieStore;
    OpalPrivacyMeasurements *observer = store && cookie_stores ? [cookie_stores objectForKey:store] : nil;
    if (observer) [observer cookiesDidChangeInCookieStore:store];
    if (wake_ui) wake_ui();
}
- (void)cookiesDidChangeInCookieStore:(WKHTTPCookieStore *)store {
    if (![policy[@"clean_tracking_cookies"] boolValue]) return;
    [store getAllCookies:^(NSArray<NSHTTPCookie *> *cookies) {
        if (![policy[@"clean_tracking_cookies"] boolValue]) return;
        for (NSHTTPCookie *cookie in cookies) {
            NSString *name = cookie.name;
            BOOL tracking = [@[@"_ga", @"_gid", @"_gat", @"_fbp", @"_fbc", @"_gcl_au", @"__utma", @"__utmb", @"__utmc", @"__utmt", @"__utmz"] containsObject:name] || [name hasPrefix:@"_ga_"] || [name hasPrefix:@"_gat_"];
            if (!tracking) continue;
            NSString *key = [NSString stringWithFormat:@"%@\n%@\n%@", cookie.domain, cookie.path, name];
            if ([self.deleting containsObject:key]) continue;
            [self.deleting addObject:key];
            [store deleteCookie:cookie completionHandler:^{
                [self.deleting removeObject:key]; ++counters[self.private][3]; if (wake_ui) wake_ui();
            }];
        }
    }];
}
@end
static void apply_rules(WKUserContentController *content, unsigned selected) {
    for (WKContentRuleList *list in rule_lists.allValues) [content removeContentRuleList:list];
    if (rule_lists[@(selected)]) [content addContentRuleList:rule_lists[@(selected)]];
}
static void prepare_rules(unsigned selected) {
    if (!selected || rule_lists[@(selected)] || [compiling containsObject:@(selected)]) return;
    [compiling addObject:@(selected)];
    NSMutableArray *rules = [NSMutableArray new];
    NSArray *domains = selected == 3 ? [ad_domains arrayByAddingObjectsFromArray:tracker_domains] : selected == 1 ? ad_domains : tracker_domains;
    for (NSString *host in domains) {
        NSString *escaped = [host stringByReplacingOccurrencesOfString:@"." withString:@"\\."];
        [rules addObject:@{@"trigger":@{@"url-filter":[NSString stringWithFormat:@"^https?://([^/]+\\.)?%@[:/]", escaped]}, @"action":@{@"type":@"block"}}];
    }
    NSString *json = [[NSString alloc] initWithData:[NSJSONSerialization dataWithJSONObject:rules options:0 error:nil] encoding:NSUTF8StringEncoding];
    [WKContentRuleListStore.defaultStore compileContentRuleListForIdentifier:[NSString stringWithFormat:@"opal-browser-shield-v1-%u", selected] encodedContentRuleList:json completionHandler:^(WKContentRuleList *list, NSError *error) {
        [compiling removeObject:@(selected)];
        if (!list) return;
        rule_lists[@(selected)] = list;
        for (WKUserContentController *content in contents) if ([contents objectForKey:content].unsignedIntValue == selected) apply_rules(content, selected);
        if (wake_ui) wake_ui();
    }];
}
void opal_security_install(WKWebViewConfiguration *config, BOOL private) {
    if (!policy || !measurement_script) return;
    if (!contents) contents = [NSMapTable weakToStrongObjectsMapTable];
    WKUserContentController *content = config.userContentController;
    [contents setObject:@(mask()) forKey:content];
    apply_rules(content, mask()); prepare_rules(mask());
    WKContentWorld *world = WKContentWorld.defaultClientWorld;
    [content removeScriptMessageHandlerForName:@"opalPrivacy" contentWorld:world];
    OpalPrivacyMeasurements *bridge = [OpalPrivacyMeasurements new]; bridge.private = private;
    [content addScriptMessageHandler:bridge contentWorld:world name:@"opalPrivacy"];
    // Only the public protection switches/domains enter the page's world.
    NSDictionary *script_policy = @{@"block_ads":@([policy[@"block_ads"] boolValue]), @"block_trackers":@([policy[@"block_trackers"] boolValue]), @"ad_domains":ad_domains, @"tracker_domains":tracker_domains};
    NSString *json = [[NSString alloc] initWithData:[NSJSONSerialization dataWithJSONObject:script_policy options:0 error:nil] encoding:NSUTF8StringEncoding];
    NSString *source = [measurement_script stringByReplacingOccurrencesOfString:@"__OPAL_POLICY__" withString:json];
    [content addUserScript:[[WKUserScript alloc] initWithSource:source injectionTime:WKUserScriptInjectionTimeAtDocumentStart forMainFrameOnly:NO inContentWorld:world]];
    if ([policy[@"block_webrtc"] boolValue] || [policy[@"proxy_mode"] isEqual:@"tor"]) {
        NSString *rtc = @"for(const k of ['RTCPeerConnection','webkitRTCPeerConnection']){try{Object.defineProperty(window,k,{value:undefined,writable:false,configurable:false})}catch(e){}}";
        [content addUserScript:[[WKUserScript alloc] initWithSource:rtc injectionTime:WKUserScriptInjectionTimeAtDocumentStart forMainFrameOnly:NO]];
    }
    if (!cookie_stores) cookie_stores = [NSMapTable weakToStrongObjectsMapTable];
    WKHTTPCookieStore *store = config.websiteDataStore.httpCookieStore;
    OpalPrivacyMeasurements *observer = [cookie_stores objectForKey:store];
    if (!observer) {
        observer = [OpalPrivacyMeasurements new]; observer.private = private; observer.store = store; observer.deleting = [NSMutableSet new];
        [cookie_stores setObject:observer forKey:store]; [store addObserver:observer];
    }
    [observer cookiesDidChangeInCookieStore:store];
}

// A pool contains only endpoints that completed a real HTTPS request through
// their configured proxy. No direct fallback; successful leases last six hours.
static NSArray<NSDictionary *> *pool_profiles;
static NSMutableArray<NSNumber *> *pool_health, *pool_expiry;
static NSMutableArray<NSURLSession *> *pool_sessions;
static unsigned pool_epoch;
static NSInteger pool_selected = -1;
static NSInteger verified_index(void) {
    NSTimeInterval now = NSDate.date.timeIntervalSince1970;
    if (pool_selected >= 0 && pool_selected < (NSInteger)pool_profiles.count && pool_health[pool_selected].intValue == 2 && pool_expiry[pool_selected].doubleValue > now) return pool_selected;
    for (NSUInteger i = 0; i < pool_profiles.count; ++i) if (pool_health[i].intValue == 2 && pool_expiry[i].doubleValue > now) return i;
    return -1;
}
NSDictionary *opal_security_pool_profile(void) {
    pool_selected = verified_index(); return pool_selected >= 0 ? pool_profiles[pool_selected] : nil;
}
static nw_proxy_config_t make_proxy(NSDictionary *p) {
    NSString *host = p[@"host"];
    if ([host hasPrefix:@"["] && [host hasSuffix:@"]"]) host = [host substringWithRange:NSMakeRange(1,host.length-2)];
    nw_endpoint_t endpoint = nw_endpoint_create_host(host.UTF8String, [p[@"port"] stringValue].UTF8String);
    nw_proxy_config_t proxy = [p[@"kind"] isEqual:@"socks5"] ? nw_proxy_config_create_socksv5(endpoint) : nw_proxy_config_create_http_connect(endpoint, [p[@"kind"] isEqual:@"https"] ? nw_tls_create_options() : nil);
    nw_proxy_config_set_failover_allowed(proxy, false); nw_proxy_config_clear_excluded_domains(proxy); nw_proxy_config_add_match_domain(proxy, "");
    NSString *user = p[@"username"], *pass = p[@"password"];
    if (user.length) nw_proxy_config_set_username_and_password(proxy,user.UTF8String,pass.UTF8String);
    return proxy;
}
void opal_security_pool_scan(void) {
    ++pool_epoch;
    for (NSURLSession *session in pool_sessions) [session invalidateAndCancel];
    pool_sessions = [NSMutableArray new]; pool_profiles = [policy[@"profiles"] copy] ?: @[];
    pool_health = [NSMutableArray new]; pool_expiry = [NSMutableArray new]; pool_selected = -1;
    for (NSUInteger i = 0; i < pool_profiles.count; ++i) { [pool_health addObject:@1]; [pool_expiry addObject:@0]; }
    unsigned epoch = pool_epoch;
    if (@available(macOS 14.0, *)) for (NSUInteger i = 0; i < pool_profiles.count; ++i) {
        NSURLSessionConfiguration *config = NSURLSessionConfiguration.ephemeralSessionConfiguration;
        config.proxyConfigurations = @[make_proxy(pool_profiles[i])]; config.timeoutIntervalForRequest = 8; config.timeoutIntervalForResource = 10;
        config.HTTPCookieStorage = nil; config.URLCache = nil;
        NSURLSession *session = [NSURLSession sessionWithConfiguration:config]; [pool_sessions addObject:session];
        NSURL *url = [NSURL URLWithString:@"https://example.com/"];
        [[session dataTaskWithURL:url completionHandler:^(NSData *data, NSURLResponse *response, NSError *error) {
            dispatch_async(dispatch_get_main_queue(), ^{
                if (epoch != pool_epoch) return;
                NSHTTPURLResponse *http = [response isKindOfClass:NSHTTPURLResponse.class] ? (NSHTTPURLResponse *)response : nil;
                BOOL ok = !error && http.statusCode >= 200 && http.statusCode < 400 && [http.URL.scheme isEqual:@"https"];
                pool_health[i] = ok ? @2 : @(-1); pool_expiry[i] = ok ? @(NSDate.date.timeIntervalSince1970 + 21600) : @0;
                [session finishTasksAndInvalidate]; signal_change();
            });
        }] resume];
    }
    signal_change();
}
int opal_security_pool_health(int index) { return index >= 0 && index < (int)pool_health.count ? pool_health[index].intValue : 0; }
int opal_security_pool_selected(void) { return (int)verified_index(); }
void opal_security_test_pool_lease(int index, double seconds) {
    if (index < 0 || index >= (int)pool_profiles.count) return;
    pool_health[index] = @2; pool_expiry[index] = @(NSDate.date.timeIntervalSince1970 + seconds);
}
int opal_security_pool_count(void) { int n=0; for (NSUInteger i=0;i<pool_health.count;++i) if(pool_health[i].intValue==2 && pool_expiry[i].doubleValue>NSDate.date.timeIntervalSince1970) ++n; return n; }
void opal_security_pool_rotate(void) {
    NSInteger current = verified_index();
    for (NSUInteger i = 1; i <= pool_profiles.count; ++i) {
        NSUInteger next = (MAX(current, 0) + i) % pool_profiles.count;
        if (pool_health[next].intValue == 2 && pool_expiry[next].doubleValue > NSDate.date.timeIntervalSince1970) { pool_selected = next; signal_change(); return; }
    }
}
void opal_security_route_failed(void) {
    if ([policy[@"proxy_mode"] isEqual:@"pool"] && pool_selected >= 0) { pool_health[pool_selected] = @(-1); pool_expiry[pool_selected] = @0; pool_selected = -1; signal_change(); }
}

static NSTask *tor_task;
static unsigned tor_epoch;
static int tor_state, tor_progress, tor_port;
static BOOL tor_requested;
static NSString *tor_message = @"Tor is off";
int opal_security_tor_status(void) { return tor_state; } // 0 off, 1 starting, 2 ready, -1 failed
int opal_security_tor_pid(void) { return tor_task.running ? tor_task.processIdentifier : 0; }
int opal_security_test_tor_listener(void) {
    if (!tor_task.running || tor_port <= 0) return 0;
    int fd=socket(AF_INET,SOCK_STREAM,0); if(fd<0)return 0;
    struct timeval timeout={.tv_usec=50000};setsockopt(fd,SOL_SOCKET,SO_RCVTIMEO,&timeout,sizeof(timeout));
    int no_sigpipe=1;setsockopt(fd,SOL_SOCKET,SO_NOSIGPIPE,&no_sigpipe,sizeof(no_sigpipe));
    struct sockaddr_in address={.sin_len=sizeof(address),.sin_family=AF_INET,.sin_port=htons(tor_port),.sin_addr={htonl(INADDR_LOOPBACK)}};
    unsigned char hello[]={5,1,0},reply[2]={0};
    BOOL ok=connect(fd,(struct sockaddr *)&address,sizeof(address))==0 && send(fd,hello,sizeof(hello),0)==sizeof(hello) && recv(fd,reply,sizeof(reply),0)==2 && reply[0]==5 && reply[1]==0;
    close(fd);return ok;
}
int opal_security_tor_progress(void) { return tor_progress; }
int opal_security_tor_port(void) { return tor_state == 2 && tor_task.running ? tor_port : 9; }
size_t opal_security_tor_message(char *out, size_t cap) { if (!cap) return 0; NSData *d=[tor_message dataUsingEncoding:NSUTF8StringEncoding]; size_t n=MIN(d.length,cap-1); memcpy(out,d.bytes,n);out[n]=0;return n; }
static void stop_tor(void) {
    ++tor_epoch; NSTask *task = tor_task; tor_task = nil; tor_state=0; tor_progress=0; tor_port=0; tor_message=@"Tor is off";
    if (task.running) { [task terminate]; dispatch_after(dispatch_time(DISPATCH_TIME_NOW,2*NSEC_PER_SEC),dispatch_get_global_queue(QOS_CLASS_UTILITY,0),^{if(task.running)kill(task.processIdentifier,SIGKILL);}); }
}
void opal_security_tor_retry(void) { stop_tor(); tor_requested=NO; signal_change(); }
static void start_tor(NSString *directory) {
    tor_requested=YES; tor_state=-1; tor_message=@"Install Tor to enable this route (brew install tor).";
    NSMutableArray *paths=[NSMutableArray arrayWithObjects:[NSBundle.mainBundle pathForResource:@"tor" ofType:nil] ?: @"", @"/opt/homebrew/bin/tor", @"/usr/local/bin/tor", @"/usr/bin/tor", nil];
    NSString *executable=nil; for(NSString *p in paths)if([NSFileManager.defaultManager isExecutableFileAtPath:p]){executable=p;break;}
    if(!executable){signal_change();return;}
    NSError *error=nil; if(![NSFileManager.defaultManager createDirectoryAtPath:directory withIntermediateDirectories:YES attributes:@{NSFilePosixPermissions:@0700} error:&error]){tor_message=@"Cannot create Tor data directory.";signal_change();return;}
    NSString *config_path=[directory stringByAppendingPathComponent:@"browser.torrc"];
    if(![@"# Managed browser route\n" writeToFile:config_path atomically:YES encoding:NSUTF8StringEncoding error:&error]){tor_message=@"Cannot write Tor configuration.";signal_change();return;}
    [NSFileManager.defaultManager setAttributes:@{NSFilePosixPermissions:@0600} ofItemAtPath:config_path error:nil];
    int fd=socket(AF_INET,SOCK_STREAM,0); struct sockaddr_in address={.sin_len=sizeof(address),.sin_family=AF_INET,.sin_port=0,.sin_addr={htonl(INADDR_LOOPBACK)}};
    socklen_t length=sizeof(address);
    if(fd<0 || bind(fd,(struct sockaddr *)&address,sizeof(address)) || getsockname(fd,(struct sockaddr *)&address,&length)){if(fd>=0)close(fd);tor_message=@"Cannot reserve a local Tor port.";signal_change();return;}
    tor_port=ntohs(address.sin_port);close(fd);
    tor_task=[NSTask new]; tor_task.executableURL=[NSURL fileURLWithPath:executable];
    tor_task.arguments=@[@"--defaults-torrc",config_path,@"-f",config_path,@"--RunAsDaemon",@"0",@"--ClientOnly",@"1",@"--ControlPort",@"0",@"--SocksPort",[NSString stringWithFormat:@"127.0.0.1:%d",tor_port],@"--DataDirectory",directory,@"--AvoidDiskWrites",@"1",@"--Log",@"notice stdout"];
    NSPipe *pipe=[NSPipe pipe];tor_task.standardOutput=pipe;tor_task.standardError=pipe;
    unsigned epoch=++tor_epoch; tor_state=1;tor_progress=0;tor_message=@"Connecting to Tor…";
    NSMutableString *pending=[NSMutableString new];
    pipe.fileHandleForReading.readabilityHandler=^(NSFileHandle *handle){
        NSData *data=handle.availableData;if(!data.length){handle.readabilityHandler=nil;return;}
        NSString *chunk=[[NSString alloc]initWithData:data encoding:NSUTF8StringEncoding] ?: @"";
        dispatch_async(dispatch_get_main_queue(),^{
            if(epoch!=tor_epoch)return;[pending appendString:chunk];
            NSRegularExpression *re=[NSRegularExpression regularExpressionWithPattern:@"Bootstrapped ([0-9]{1,3})%" options:0 error:nil];
            for(NSTextCheckingResult *m in [re matchesInString:pending options:0 range:NSMakeRange(0,pending.length)]){tor_progress=MIN(100,[[pending substringWithRange:[m rangeAtIndex:1]]intValue]);if(tor_progress==100){tor_state=2;tor_message=@"Connected to Tor";}}
            if(pending.length>4096)[pending deleteCharactersInRange:NSMakeRange(0,pending.length-256)];signal_change();
        });
    };
    tor_task.terminationHandler=^(NSTask *task){dispatch_async(dispatch_get_main_queue(),^{if(epoch!=tor_epoch)return;tor_state=-1;tor_message=@"Tor stopped. Traffic stays blocked until you reconnect or change routes.";signal_change();});};
    if(![tor_task launchAndReturnError:&error]){pipe.fileHandleForReading.readabilityHandler=nil;tor_state=-1;tor_message=@"Tor could not start. Check its installation and retry.";}
    signal_change();
}
void opal_security_tick(const char *directory, int use_tor) {
    if(use_tor && !tor_requested)start_tor([NSString stringWithUTF8String:directory]);
    else if(!use_tor && tor_requested){stop_tor();tor_requested=NO;signal_change();}
    if([policy[@"proxy_mode"]isEqual:@"pool"] && pool_selected>=0 && verified_index()!=pool_selected){pool_selected=-1;signal_change();}
}
int opal_security_route_ready(NSString *mode) {
    if([mode isEqual:@"tor"])return tor_state==2 && tor_task.running;
    if([mode isEqual:@"pool"])return verified_index()>=0;
    return 1;
}
void opal_security_configure(NSDictionary *settings, NSString *script, void (*wake)(void)) {
    if(!ad_domains){ad_domains=@[@"doubleclick.net",@"googlesyndication.com",@"googleadservices.com",@"adnxs.com",@"adsrvr.org"];tracker_domains=@[@"google-analytics.com",@"googletagmanager.com",@"scorecardresearch.com",@"hotjar.com",@"clarity.ms"];rule_lists=[NSMutableDictionary new];compiling=[NSMutableSet new];}
    if(policy && ![policy[@"profiles"]isEqual:settings[@"profiles"]]){++pool_epoch;for(NSURLSession *s in pool_sessions)[s invalidateAndCancel];pool_profiles=nil;pool_health=nil;pool_expiry=nil;pool_selected=-1;signal_change();}
    policy=[settings copy];measurement_script=[script copy];wake_ui=wake;
}
void opal_security_shutdown(void) {
    wake_ui=NULL;stop_tor();tor_requested=NO;++pool_epoch;for(NSURLSession *s in pool_sessions)[s invalidateAndCancel];
}
