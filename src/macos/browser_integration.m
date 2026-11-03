// First-party browser bridge: messages stay inside WebKit/native memory.
#import <AppKit/AppKit.h>
#import <ImageIO/ImageIO.h>
#import <Network/NSURLSession+Network.h>
#import <CommonCrypto/CommonDigest.h>
#import "browser_integration.h"
#include <sys/stat.h>
#include <unistd.h>
#include <fcntl.h>
static NSString *extension_path, *cache_path;
static NSDictionary *policy;
static WKWebExtensionContext *integration;
static NSString *integration_error;
static BOOL background_ready;
static unsigned long long received_messages;
static unsigned generation;
static unsigned handoff_serial;
static BOOL private_context;
static void (*wake_ui)(void);
static NSDictionary *pending;
static NSDictionary *pending_comic;
static unsigned long long icon_revision=1,next_session=1;
@interface OpalBrowserMediaSession : NSObject <NSURLSessionTaskDelegate>
@property NSURLSession *session;
@property NSString *cookieFile;
@property NSString *configFile;
@property NSString *proxy;
@property BOOL testLocal;
@property unsigned refs;
@end
// Per-task buffering is bounded even if an upstream ignores the requested range.
@interface OpalBrowserMediaFetch : NSObject <NSURLSessionDataDelegate>
@property NSMutableData *body;
@property NSUInteger limit;
@property dispatch_semaphore_t done;
@property NSInteger code;
@property BOOL ok;
@end
@implementation OpalBrowserMediaFetch
- (void)URLSession:(NSURLSession *)session dataTask:(NSURLSessionDataTask *)task didReceiveResponse:(NSURLResponse *)response completionHandler:(void (^)(NSURLSessionResponseDisposition))done {
 self.code=[response isKindOfClass:NSHTTPURLResponse.class]?[(NSHTTPURLResponse *)response statusCode]:0;
 done(response.expectedContentLength>(long long)self.limit?NSURLSessionResponseCancel:NSURLSessionResponseAllow);
}
- (void)URLSession:(NSURLSession *)session dataTask:(NSURLSessionDataTask *)task didReceiveData:(NSData *)data {
 if(self.body.length+data.length>self.limit){[task cancel];return;}[self.body appendData:data];
}
- (void)URLSession:(NSURLSession *)session task:(NSURLSessionTask *)task didCompleteWithError:(NSError *)error {
 self.ok=!error;dispatch_semaphore_signal(self.done);
}
@end
@implementation OpalBrowserMediaSession
- (void)URLSession:(NSURLSession *)session task:(NSURLSessionTask *)task willPerformHTTPRedirection:(NSHTTPURLResponse *)response newRequest:(NSURLRequest *)request completionHandler:(void (^)(NSURLRequest *))done {
 NSString *host=request.URL.host.lowercaseString;
 if(![request.URL.scheme isEqual:@"https"] || !([host isEqual:@"googlevideo.com"] || [host hasSuffix:@".googlevideo.com"])) {done(nil);return;}
 NSMutableURLRequest *next=[request mutableCopy];
 if(![task.currentRequest.URL.host isEqual:host]){[next setValue:nil forHTTPHeaderField:@"Cookie"];[next setValue:nil forHTTPHeaderField:@"Authorization"];}
 done(next);
}
@end
static NSMutableDictionary<NSNumber *,OpalBrowserMediaSession *> *sessions;
static NSLock *session_lock;
static NSString *host_for(NSString *url) {
 NSURL *u=[NSURL URLWithString:url];NSString *host=u.host.lowercaseString;
 if(![@[@"http",@"https"]containsObject:u.scheme.lowercaseString] || !host.length)return nil;
 return [host hasPrefix:@"www."]?[host substringFromIndex:4]:host;
}
static NSString *icon_path(NSString *url) {
 NSString *host=host_for(url);if(!host || !cache_path)return nil;
 NSData *data=[host dataUsingEncoding:NSUTF8StringEncoding];unsigned char digest[CC_SHA256_DIGEST_LENGTH];CC_SHA256(data.bytes,(CC_LONG)data.length,digest);
 NSMutableString *key=[NSMutableString new];for(int i=0;i<32;i++)[key appendFormat:@"%02x",digest[i]];
 return [cache_path stringByAppendingPathComponent:[key stringByAppendingString:@".png"]];
}
void opal_browser_integration_configure(const char *directory,const char *cache) {
 extension_path=*directory?[NSString stringWithUTF8String:directory]:nil;cache_path=*cache?[NSString stringWithUTF8String:cache]:nil;
 if(!extension_path || !cache_path)return;
 [NSFileManager.defaultManager createDirectoryAtPath:cache_path withIntermediateDirectories:YES attributes:@{NSFilePosixPermissions:@0700} error:nil];
 if(!sessions){sessions=[NSMutableDictionary new];session_lock=[NSLock new];}
}
void opal_browser_integration_policy(NSDictionary *settings){policy=[settings copy];}
unsigned long long opal_browser_icon_revision(void){return icon_revision;}
size_t opal_browser_icon_copy(const char *url,unsigned char *out,size_t cap){
 NSString *path=icon_path([NSString stringWithUTF8String:url]);if(!path)return 0;
 NSData *data=[NSData dataWithContentsOfFile:path options:NSDataReadingMappedIfSafe error:nil];
 if(!data.length || data.length>cap)return 0;memcpy(out,data.bytes,data.length);return data.length;
}
static BOOL save_icon(NSDictionary *message){
 NSString *path=icon_path(message[@"url"]);NSString *encoded=message[@"data"];
 if(!path || ![encoded isKindOfClass:NSString.class] || encoded.length>90000)return NO;
 NSData *data=[[NSData alloc]initWithBase64EncodedString:encoded options:0];if(!data || data.length>65536)return NO;
 CGImageSourceRef source=CGImageSourceCreateWithData((__bridge CFDataRef)data,NULL);if(!source)return NO;
 NSDictionary *props=CFBridgingRelease(CGImageSourceCopyPropertiesAtIndex(source,0,NULL));
 if([props[(__bridge NSString *)kCGImagePropertyPixelWidth]unsignedLongValue]>1024 || [props[(__bridge NSString *)kCGImagePropertyPixelHeight]unsignedLongValue]>1024){CFRelease(source);return NO;}
 CGImageRef image=CGImageSourceCreateThumbnailAtIndex(source,0,(__bridge CFDictionaryRef)@{(__bridge NSString *)kCGImageSourceCreateThumbnailFromImageAlways:@YES,(__bridge NSString *)kCGImageSourceThumbnailMaxPixelSize:@64});CFRelease(source);if(!image)return NO;
 NSMutableData *png=[NSMutableData new];CGImageDestinationRef dest=CGImageDestinationCreateWithData((__bridge CFMutableDataRef)png,CFSTR("public.png"),1,NULL);
 if(!dest){CGImageRelease(image);return NO;}CGImageDestinationAddImage(dest,image,NULL);BOOL ok=CGImageDestinationFinalize(dest);CFRelease(dest);CGImageRelease(image);
 if(ok)ok=[png writeToFile:path options:NSDataWritingAtomic error:nil];if(ok){++icon_revision;if(wake_ui)wake_ui();}return ok;
}
static NSString *youtube_id(NSString *value){
 NSURLComponents *u=[NSURLComponents componentsWithString:value];NSString *host=u.host.lowercaseString;
 if(![u.scheme isEqual:@"https"] || !([host isEqual:@"youtube.com"] || [host hasSuffix:@".youtube.com"]))return nil;
 NSString *id=nil;if([u.path isEqual:@"/watch"])for(NSURLQueryItem *item in u.queryItems)if([item.name isEqual:@"v"])id=item.value;
 NSArray *parts=[u.path componentsSeparatedByString:@"/"];if(!id && parts.count>2 && [@[@"shorts",@"live",@"embed"]containsObject:parts[1]])id=parts[2];
 if(id.length!=11 || [id rangeOfCharacterFromSet:[[NSCharacterSet characterSetWithCharactersInString:@"ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789_-"]invertedSet]].location!=NSNotFound)return nil;return id;
}
static NSString *cookie_file(NSArray<NSHTTPCookie *> *cookies){
 if(!cache_path)return nil;NSString *pattern=[cache_path stringByAppendingPathComponent:@"session-XXXXXX"];
 char *name=strdup(pattern.fileSystemRepresentation);int fd=mkstemp(name);if(fd<0){free(name);return nil;}fchmod(fd,0600);
 NSMutableString *text=[NSMutableString stringWithString:@"# Netscape HTTP Cookie File\n"];
 for(NSHTTPCookie *cookie in cookies){NSString *domain=cookie.domain.lowercaseString;NSString *bare=[domain hasPrefix:@"."]?[domain substringFromIndex:1]:domain;
  if(!([bare isEqual:@"youtube.com"] || [bare hasSuffix:@".youtube.com"] || [bare isEqual:@"googlevideo.com"] || [bare hasSuffix:@".googlevideo.com"]))continue;
  BOOL safe=YES;for(NSString *field in @[domain,cookie.path,cookie.name,cookie.value])if([field rangeOfCharacterFromSet:[NSCharacterSet characterSetWithCharactersInString:@"\r\n\t"]].location!=NSNotFound)safe=NO;
  if(!safe)continue;
  [text appendFormat:@"%@%@\t%@\t%@\t%@\t%.0f\t%@\t%@\n",cookie.HTTPOnly?@"#HttpOnly_":@"",domain,[domain hasPrefix:@"."]?@"TRUE":@"FALSE",cookie.path,cookie.secure?@"TRUE":@"FALSE",cookie.expiresDate?cookie.expiresDate.timeIntervalSince1970:0,cookie.name,cookie.value];
 }
 NSData *data=[text dataUsingEncoding:NSUTF8StringEncoding];BOOL ok=data.length<=131072 && write(fd,data.bytes,data.length)==data.length;close(fd);
 NSString *path=[NSFileManager.defaultManager stringWithFileSystemRepresentation:name length:strlen(name)];if(!ok){unlink(name);path=nil;}free(name);return path;
}
static NSString *proxy_url(void){
 NSString *mode=policy[@"proxy_mode"];if([mode isEqual:@"system"] || !mode)return @"";
 NSDictionary *profile=nil;
 if([mode isEqual:@"tor"]){extern int opal_security_tor_port(void);profile=@{@"kind":@"socks5",@"host":@"127.0.0.1",@"port":@(opal_security_tor_port())};}
 else if([mode isEqual:@"pool"]){extern NSDictionary *opal_security_pool_profile(void);profile=opal_security_pool_profile();}
 else{NSArray *rows=policy[@"profiles"];NSUInteger i=[policy[@"active_profile"]unsignedIntegerValue];if(i<rows.count)profile=rows[i];}
 if(!profile)return @"socks5h://127.0.0.1:9";
 NSURLComponents *u=[NSURLComponents new];u.scheme=[profile[@"kind"]isEqual:@"socks5"]?@"socks5h":profile[@"kind"];u.host=profile[@"host"];u.port=profile[@"port"];
 if([profile[@"username"]length]){u.user=profile[@"username"];u.password=profile[@"password"]?:@"";}return u.string?:@"socks5h://127.0.0.1:9";
}
void opal_browser_media_retain(unsigned long long token){[session_lock lock];sessions[@(token)].refs++;[session_lock unlock];}
void opal_browser_media_release(unsigned long long token){
 if(!token)return;[session_lock lock];OpalBrowserMediaSession *s=sessions[@(token)];if(s && --s.refs==0){[sessions removeObjectForKey:@(token)];[s.session invalidateAndCancel];if(s.cookieFile)[NSFileManager.defaultManager removeItemAtPath:s.cookieFile error:nil];if(s.configFile)[NSFileManager.defaultManager removeItemAtPath:s.configFile error:nil];}[session_lock unlock];
}
static NSString *quoted(NSString *value) {
 if([value rangeOfCharacterFromSet:NSCharacterSet.newlineCharacterSet].location!=NSNotFound)return nil;
 return [NSString stringWithFormat:@"\"%@\"",[[value stringByReplacingOccurrencesOfString:@"\\" withString:@"\\\\"]stringByReplacingOccurrencesOfString:@"\"" withString:@"\\\""]];
}
size_t opal_browser_media_config(unsigned long long token,const char *agent,char *out,size_t cap){
 [session_lock lock];OpalBrowserMediaSession *s=sessions[@(token)];[session_lock unlock];if(!s)return 0;
 NSString *ua=quoted([NSString stringWithUTF8String:agent]), *proxy=quoted(s.proxy?:@"");if(!ua || !proxy)return 0;
 NSString *path=[s.cookieFile stringByAppendingString:@".conf"];
 NSString *proxy_line=s.proxy.length?[NSString stringWithFormat:@"--proxy %@\n",proxy]:@"";
 NSString *text=[NSString stringWithFormat:@"--cookies %@\n%@--user-agent %@\n--referer https://www.youtube.com/\n--js-runtimes node\n",quoted(s.cookieFile),proxy_line,ua];
 NSData *data=[text dataUsingEncoding:NSUTF8StringEncoding];
 int fd=open(path.fileSystemRepresentation,O_WRONLY|O_CREAT|O_TRUNC|O_NOFOLLOW|O_CLOEXEC,0600);if(fd<0)return 0;
 BOOL ok=write(fd,data.bytes,data.length)==data.length;close(fd);if(!ok){unlink(path.fileSystemRepresentation);return 0;}s.configFile=path;
 NSData *bytes=[path dataUsingEncoding:NSUTF8StringEncoding];if(bytes.length>=cap)return 0;memcpy(out,bytes.bytes,bytes.length);out[bytes.length]=0;return bytes.length;
}
size_t opal_browser_media_fetch(unsigned long long token,const char *url,const char *headers,const char *range,unsigned char *out,size_t cap,int *status){@autoreleasepool{
 [session_lock lock];OpalBrowserMediaSession *s=sessions[@(token)];[session_lock unlock];if(!s)return 0;
 NSURL *target=[NSURL URLWithString:[NSString stringWithUTF8String:url]];NSString *host=target.host.lowercaseString;
 BOOL fixture=s.testLocal && [target.scheme isEqual:@"http"] && [host isEqual:@"127.0.0.1"];
 if(!fixture && (![target.scheme isEqual:@"https"] || !([host isEqual:@"googlevideo.com"] || [host hasSuffix:@".googlevideo.com"])))return 0;
 NSMutableURLRequest *request=[NSMutableURLRequest requestWithURL:target];request.timeoutInterval=12;
 NSData *json=[[NSString stringWithUTF8String:headers]dataUsingEncoding:NSUTF8StringEncoding];NSDictionary *fields=[NSJSONSerialization JSONObjectWithData:json options:0 error:nil];if(![fields isKindOfClass:NSDictionary.class])return 0;
 for(NSString *key in fields)[request setValue:fields[key] forHTTPHeaderField:key];
 if(range && *range)[request setValue:[NSString stringWithUTF8String:range] forHTTPHeaderField:@"Range"];
 OpalBrowserMediaFetch *fetch=[OpalBrowserMediaFetch new];fetch.body=[NSMutableData new];fetch.limit=cap;fetch.done=dispatch_semaphore_create(0);
 NSURLSessionDataTask *task=[s.session dataTaskWithRequest:request];task.delegate=fetch;[task resume];
 if(dispatch_semaphore_wait(fetch.done,dispatch_time(DISPATCH_TIME_NOW,14*NSEC_PER_SEC))){[task cancel];return 0;}*status=(int)fetch.code;
 if(!fetch.ok || fetch.body.length>cap)return 0;memcpy(out,fetch.body.bytes,fetch.body.length);return fetch.body.length;
}}
size_t opal_browser_media_take(char *out,size_t cap){
 if(!pending)return 0;NSData *data=[NSJSONSerialization dataWithJSONObject:pending options:0 error:nil];if(!data || data.length>=cap)return 0;memcpy(out,data.bytes,data.length);out[data.length]=0;pending=nil;return data.length;
}
size_t opal_browser_comic_take(char *out,size_t cap){
 if(!pending_comic)return 0;NSData *data=[NSJSONSerialization dataWithJSONObject:pending_comic options:0 error:nil];if(!data || data.length>=cap)return 0;
 memcpy(out,data.bytes,data.length);out[data.length]=0;pending_comic=nil;return data.length;
}
BOOL opal_browser_integration_message(WKWebExtensionContext *context,id raw,WKWebView *page,void (^reply)(id,NSError *)){
 if(context!=integration)return NO;
 ++received_messages;
 if(![raw isKindOfClass:NSDictionary.class]){reply(@{@"ok":@NO},nil);return YES;}
 NSDictionary *message=raw;
 if([message[@"what"]isEqual:@"favicon"]){reply(@{@"ok":@(!private_context && save_icon(message))},nil);return YES;}
 if([message[@"what"]isEqual:@"read-comic"]){
  if(!page.URL || ![message[@"url"]isKindOfClass:NSString.class] || ![NSJSONSerialization isValidJSONObject:message]){reply(@{@"ok":@NO},nil);return YES;}
  NSURLComponents *source=[NSURLComponents componentsWithString:message[@"url"]],*current=[NSURLComponents componentsWithURL:page.URL resolvingAgainstBaseURL:NO];source.fragment=nil;current.fragment=nil;
  if(!source || !current || ![@[@"http",@"https"]containsObject:source.scheme.lowercaseString] || ![source.URL isEqual:current.URL] || [NSJSONSerialization dataWithJSONObject:message options:0 error:nil].length>8192){reply(@{@"ok":@NO},nil);return YES;}
  ++handoff_serial;if(pending){opal_browser_media_release([pending[@"session"]unsignedLongLongValue]);pending=nil;}pending_comic=[message copy];
  if(wake_ui)wake_ui();reply(@{@"ok":@YES},nil);return YES;
 }
 NSString *id=youtube_id(message[@"url"]);NSString *current=youtube_id(page.URL.absoluteString);
 if(![message[@"what"]isEqual:@"play-youtube"] || !id || ![id isEqual:current] || ![NSJSONSerialization isValidJSONObject:message]){reply(@{@"ok":@NO},nil);return YES;}
 if([NSJSONSerialization dataWithJSONObject:message options:0 error:nil].length>60000){reply(@{@"ok":@NO},nil);return YES;}
 [session_lock lock];BOOL full=sessions.count>=32;[session_lock unlock];if(full){reply(@{@"ok":@NO,@"error":@"Too many active browser streams"},nil);return YES;}
 NSString *route=proxy_url();
 pending_comic=nil;
 unsigned request_serial=++handoff_serial, epoch=generation;
 NSArray *proxies=nil;if(@available(macOS 14.0,*))proxies=[page.configuration.websiteDataStore.proxyConfigurations copy];
 [page.configuration.websiteDataStore.httpCookieStore getAllCookies:^(NSArray<NSHTTPCookie *> *cookies){
  if(request_serial!=handoff_serial || epoch!=generation){reply(@{@"ok":@NO},nil);return;}
  NSString *file=cookie_file(cookies);if(!file){reply(@{@"ok":@NO},nil);return;}
  OpalBrowserMediaSession *session=[OpalBrowserMediaSession new];session.cookieFile=file;session.proxy=route;session.refs=1;
  NSURLSessionConfiguration *config=NSURLSessionConfiguration.ephemeralSessionConfiguration;config.HTTPCookieStorage=nil;config.URLCache=nil;config.timeoutIntervalForResource=14;
  if(@available(macOS 14.0,*))config.proxyConfigurations=proxies;
  session.session=[NSURLSession sessionWithConfiguration:config delegate:session delegateQueue:nil];
  [session_lock lock];unsigned long long token=next_session++;sessions[@(token)]=session;[session_lock unlock];
  if(pending)opal_browser_media_release([pending[@"session"]unsignedLongLongValue]);
  NSMutableDictionary *copy=[message mutableCopy];copy[@"session"]=@(token);copy[@"cookies_file"]=file;copy[@"proxy"]=route;copy[@"url"]=[NSString stringWithFormat:@"https://www.youtube.com/watch?v=%@",id];pending=copy;
  if(wake_ui)wake_ui();reply(@{@"ok":@YES},nil);
 }];return YES;
}
void opal_browser_integration_install(WKWebExtensionController *controller,BOOL private,void (*wake)(void)){
 wake_ui=wake;private_context=private;integration_error=nil;background_ready=NO;if(!extension_path)return;unsigned serial=++generation;
 [WKWebExtension extensionWithResourceBaseURL:[NSURL fileURLWithPath:extension_path] completionHandler:^(WKWebExtension *extension,NSError *error){
  if(serial!=generation)return;
  if(!extension || extension.errors.count){integration_error=error.localizedDescription?:extension.errors.firstObject.localizedDescription?:@"Browser integration failed to load";if(wake_ui)wake_ui();return;}
  WKWebExtensionContext *context=[[WKWebExtensionContext alloc]initForExtension:extension];context.uniqueIdentifier=@"opal-browser-integration";context.baseURL=[NSURL URLWithString:@"webkit-extension://opal-browser-integration/"];context.hasAccessToPrivateData=private;
  for(NSString *permission in extension.requestedPermissions)[context setPermissionStatus:WKWebExtensionContextPermissionStatusGrantedExplicitly forPermission:permission];
  for(WKWebExtensionMatchPattern *pattern in extension.requestedPermissionMatchPatterns)[context setPermissionStatus:WKWebExtensionContextPermissionStatusGrantedExplicitly forMatchPattern:pattern];
  NSError *load_error=nil;
  if([controller loadExtensionContext:context error:&load_error]){integration=context;[context loadBackgroundContentWithCompletionHandler:^(NSError *error){if(serial==generation){background_ready=!error;integration_error=error.localizedDescription;if(wake_ui)wake_ui();}}];}
  else integration_error=load_error.localizedDescription?:@"Browser integration failed to start";
 }];
}
int opal_browser_integration_status(char *out,size_t cap){
 if(cap){NSData *text=[integration_error dataUsingEncoding:NSUTF8StringEncoding];size_t n=MIN(cap-1,text.length);if(n)memcpy(out,text.bytes,n);out[n]=0;}
 return integration_error?-1:integration && background_ready?2:0;
}
unsigned long long opal_browser_integration_test_messages(void){return received_messages;}
unsigned long long opal_browser_integration_test_session(void){
 if(!session_lock){session_lock=[NSLock new];sessions=[NSMutableDictionary new];}
 OpalBrowserMediaSession *s=[OpalBrowserMediaSession new];s.refs=1;s.testLocal=YES;
 NSURLSessionConfiguration *config=NSURLSessionConfiguration.ephemeralSessionConfiguration;config.HTTPCookieStorage=nil;config.URLCache=nil;
 s.session=[NSURLSession sessionWithConfiguration:config delegate:s delegateQueue:nil];
 [session_lock lock];unsigned long long token=next_session++;sessions[@(token)]=s;[session_lock unlock];return token;
}
unsigned long long opal_browser_integration_test_session_count(void){[session_lock lock];NSUInteger n=sessions.count;[session_lock unlock];return n;}
void opal_browser_integration_close(void){++generation;integration=nil;pending_comic=nil;}
void opal_browser_integration_shutdown(void){
 wake_ui=NULL;opal_browser_integration_close();[session_lock lock];NSArray *all=sessions.allValues;sessions=[NSMutableDictionary new];[session_lock unlock];
 for(OpalBrowserMediaSession *s in all){[s.session invalidateAndCancel];if(s.cookieFile)[NSFileManager.defaultManager removeItemAtPath:s.cookieFile error:nil];if(s.configFile)[NSFileManager.defaultManager removeItemAtPath:s.configFile error:nil];}
 pending=nil;
}
