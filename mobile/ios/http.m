#import <Foundation/Foundation.h>
#include <dispatch/dispatch.h>
#include <stdint.h>

typedef struct {
    const char *url, *method, *headers_json;
    const uint8_t *payload; size_t payload_len;
    uint8_t *body; size_t body_capacity, body_len;
    uint8_t *headers; size_t header_capacity, header_len;
    uint32_t timeout_seconds;
    uint16_t status;
    bool follow_redirects, https_only;
    bool (*cancelled)(void *); void *cancel_context;
} OpalHttpRequest;

@interface OpalHttpTransfer : NSObject <NSURLSessionDataDelegate>
@property(nonatomic) OpalHttpRequest *request;
@property(nonatomic) dispatch_semaphore_t finished;
@property(atomic) int failure;
@end

static BOOL same_origin(NSURL *a, NSURL *b) {
    return [a.scheme.lowercaseString isEqual:b.scheme.lowercaseString] && [a.host.lowercaseString isEqual:b.host.lowercaseString] &&
        [(a.port ?: ([a.scheme.lowercaseString isEqual:@"https"] ? @443 : @80)) isEqual:(b.port ?: ([b.scheme.lowercaseString isEqual:@"https"] ? @443 : @80))];
}

@implementation OpalHttpTransfer
- (void)URLSession:(NSURLSession *)session dataTask:(NSURLSessionDataTask *)task didReceiveResponse:(NSURLResponse *)response completionHandler:(void (^)(NSURLSessionResponseDisposition))completion {
    NSHTTPURLResponse *http = (NSHTTPURLResponse *)response;
    self.request->status = (uint16_t)http.statusCode;
    NSMutableString *headers = [NSMutableString stringWithFormat:@"HTTP/1.1 %ld\r\n", (long)http.statusCode];
    [http.allHeaderFields enumerateKeysAndObjectsUsingBlock:^(id key, id value, BOOL *stop) { [headers appendFormat:@"%@: %@\r\n", key, value]; }];
    [headers appendString:@"\r\n"];
    NSData *encoded = [headers dataUsingEncoding:NSUTF8StringEncoding];
    self.request->header_len = MIN(encoded.length, self.request->header_capacity);
    if (self.request->header_len) memcpy(self.request->headers, encoded.bytes, self.request->header_len);
    if (response.expectedContentLength > 0 && (uint64_t)response.expectedContentLength > self.request->body_capacity) {
        self.failure = 2; completion(NSURLSessionResponseCancel); return;
    }
    completion(NSURLSessionResponseAllow);
}
- (void)URLSession:(NSURLSession *)session dataTask:(NSURLSessionDataTask *)task didReceiveData:(NSData *)data {
    size_t available = self.request->body_capacity - self.request->body_len;
    if (data.length > available) { self.failure = 2; [task cancel]; return; }
    memcpy(self.request->body + self.request->body_len, data.bytes, data.length);
    self.request->body_len += data.length;
}
- (void)URLSession:(NSURLSession *)session task:(NSURLSessionTask *)task willPerformHTTPRedirection:(NSHTTPURLResponse *)response newRequest:(NSURLRequest *)request completionHandler:(void (^)(NSURLRequest *))completion {
    if (!self.request->follow_redirects) { completion(nil); return; }
    if (self.request->https_only && ![request.URL.scheme.lowercaseString isEqual:@"https"]) { self.failure = 1; completion(nil); [task cancel]; return; }
    NSMutableURLRequest *next = [request mutableCopy];
    if (same_origin(task.originalRequest.URL, request.URL)) {
        for (NSString *key in @[@"Authorization", @"Cookie"]) {
            NSString *value = [task.originalRequest valueForHTTPHeaderField:key];
            if (value) [next setValue:value forHTTPHeaderField:key];
        }
    } else {
        for (NSString *key in @[@"Authorization", @"Cookie", @"Proxy-Authorization", @"Origin"]) [next setValue:nil forHTTPHeaderField:key];
    }
    completion(next);
}
- (void)URLSession:(NSURLSession *)session task:(NSURLSessionTask *)task didCompleteWithError:(NSError *)error {
    if (error && !self.failure) self.failure = error.code == NSURLErrorTimedOut ? 3 : 1;
    dispatch_semaphore_signal(self.finished);
}
@end

int opal_apple_http_request(OpalHttpRequest *request) {
    @autoreleasepool {
        // Shared source functions are blocking worker operations. Refuse a
        // main-thread network wait instead of freezing touch/navigation.
        if (NSThread.isMainThread) return 4;
        request->body_len = request->header_len = request->status = 0;
        NSURL *url = [NSURL URLWithString:[NSString stringWithUTF8String:request->url]];
        if (!url.host.length || ![@[@"http", @"https"] containsObject:url.scheme.lowercaseString] || (request->https_only && ![url.scheme.lowercaseString isEqual:@"https"])) return 1;
        NSMutableURLRequest *native = [NSMutableURLRequest requestWithURL:url cachePolicy:NSURLRequestUseProtocolCachePolicy timeoutInterval:request->timeout_seconds];
        native.HTTPMethod = [NSString stringWithUTF8String:request->method];
        NSData *json = [[NSString stringWithUTF8String:request->headers_json] dataUsingEncoding:NSUTF8StringEncoding];
        NSArray *headers = [NSJSONSerialization JSONObjectWithData:json options:0 error:nil];
        for (NSDictionary *header in headers) [native setValue:header[@"value"] forHTTPHeaderField:header[@"name"]];
        if (request->payload_len) native.HTTPBody = [NSData dataWithBytes:request->payload length:request->payload_len];
        OpalHttpTransfer *transfer = [OpalHttpTransfer new];
        transfer.request = request; transfer.finished = dispatch_semaphore_create(0);
        NSURLSessionConfiguration *configuration = NSURLSessionConfiguration.defaultSessionConfiguration;
        configuration.timeoutIntervalForResource = request->timeout_seconds;
        NSURLSession *session = [NSURLSession sessionWithConfiguration:configuration delegate:transfer delegateQueue:nil];
        NSURLSessionDataTask *task = [session dataTaskWithRequest:native];
        [task resume];
        while (dispatch_semaphore_wait(transfer.finished, dispatch_time(DISPATCH_TIME_NOW, 50 * NSEC_PER_MSEC))) {
            if (request->cancelled && request->cancelled(request->cancel_context)) { transfer.failure = 5; [task cancel]; }
        }
        [session finishTasksAndInvalidate];
        return transfer.failure;
    }
}
