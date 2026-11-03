#import <WebKit/WebKit.h>
#import <Network/Network.h>
void opal_security_configure(NSDictionary *, NSString *, void (*)(void));
void opal_security_install(WKWebViewConfiguration *, BOOL);
NSDictionary *opal_security_pool_profile(void);
int opal_security_route_ready(NSString *);
int opal_security_tor_port(void);
void opal_security_route_failed(void);
void opal_security_shutdown(void);
