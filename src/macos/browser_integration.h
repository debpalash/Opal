#import <WebKit/WebKit.h>
void opal_browser_integration_install(WKWebExtensionController *, BOOL, void (*)(void));
void opal_browser_integration_close(void);
BOOL opal_browser_integration_message(WKWebExtensionContext *, id, WKWebView *, void (^)(id, NSError *));
void opal_browser_integration_policy(NSDictionary *);
