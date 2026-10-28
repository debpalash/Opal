// zig build test-native-about
// A bare executable must retain the Opal name and route to the full About page.
#import "../src/macos/app_menu.m"
#include <assert.h>
int main(void) {
    @autoreleasepool {
        opal_app_identity_init();
        assert([[NSProcessInfo processInfo].processName isEqualToString:@"Opal"]);
        [NSApplication sharedApplication];
        NSData *png = [NSData dataWithContentsOfFile:@"src/ui/opal_logo_64.png"];
        assert(png.length > 0);
        opal_app_menu_init(png.bytes, png.length);
        NSMenuItem *app = [NSApp.mainMenu itemAtIndex:0];
        assert([app.title isEqualToString:@"Opal"]);
        NSMenuItem *about = [app.submenu itemAtIndex:0];
        assert([about.title isEqualToString:@"About Opal"]);
        assert(about.target != nil && about.action == @selector(showAbout:));
        NSUInteger windows = NSApp.windows.count;
        [NSApp sendAction:about.action to:about.target from:about];
        assert(opal_app_menu_poll() == OPAL_MENU_ABOUT);
        assert(opal_app_menu_poll() == OPAL_MENU_NONE);
        assert(NSApp.windows.count == windows); // No duplicate standard About popup.
        NSLog(@"PASS: Opal identity and native menu action for the existing About page");
    }
    return 0;
}
