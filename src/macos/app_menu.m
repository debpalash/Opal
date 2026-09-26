// Native macOS menu bar for the SDL window. SDL only installs the application
// and Window menus, so build the complete desktop menu after the window exists.

#import <AppKit/AppKit.h>
#include <pthread.h>

enum {
    OPAL_MENU_NONE = 0,
    OPAL_MENU_OPEN = 1,
    OPAL_MENU_SETTINGS = 2,
    OPAL_MENU_HOME = 3,
    OPAL_MENU_SEARCH = 4,
    OPAL_MENU_BROWSE = 5,
    OPAL_MENU_PLAY_PAUSE = 6,
    OPAL_MENU_SEEK_BACK = 7,
    OPAL_MENU_SEEK_FORWARD = 8,
    OPAL_MENU_FULLSCREEN = 9,
};

#define OPAL_MENU_QUEUE_CAP 16
static pthread_mutex_t g_menu_lock = PTHREAD_MUTEX_INITIALIZER;
static int g_menu_queue[OPAL_MENU_QUEUE_CAP];
static int g_menu_head = 0;
static int g_menu_count = 0;

static void opal_menu_push(int action) {
    pthread_mutex_lock(&g_menu_lock);
    if (g_menu_count == OPAL_MENU_QUEUE_CAP) {
        g_menu_head = (g_menu_head + 1) % OPAL_MENU_QUEUE_CAP;
        g_menu_count--;
    }
    g_menu_queue[(g_menu_head + g_menu_count) % OPAL_MENU_QUEUE_CAP] = action;
    g_menu_count++;
    pthread_mutex_unlock(&g_menu_lock);
}

int opal_app_menu_poll(void) {
    pthread_mutex_lock(&g_menu_lock);
    int action = OPAL_MENU_NONE;
    if (g_menu_count > 0) {
        action = g_menu_queue[g_menu_head];
        g_menu_head = (g_menu_head + 1) % OPAL_MENU_QUEUE_CAP;
        g_menu_count--;
    }
    pthread_mutex_unlock(&g_menu_lock);
    return action;
}

@interface OpalMenuTarget : NSObject
@end

@implementation OpalMenuTarget
- (void)openFile:(id)sender { (void)sender; opal_menu_push(OPAL_MENU_OPEN); }
- (void)openSettings:(id)sender { (void)sender; opal_menu_push(OPAL_MENU_SETTINGS); }
- (void)showHome:(id)sender { (void)sender; opal_menu_push(OPAL_MENU_HOME); }
- (void)showSearch:(id)sender { (void)sender; opal_menu_push(OPAL_MENU_SEARCH); }
- (void)showBrowse:(id)sender { (void)sender; opal_menu_push(OPAL_MENU_BROWSE); }
- (void)playPause:(id)sender { (void)sender; opal_menu_push(OPAL_MENU_PLAY_PAUSE); }
- (void)seekBack:(id)sender { (void)sender; opal_menu_push(OPAL_MENU_SEEK_BACK); }
- (void)seekForward:(id)sender { (void)sender; opal_menu_push(OPAL_MENU_SEEK_FORWARD); }
- (void)toggleOpalFullscreen:(id)sender { (void)sender; opal_menu_push(OPAL_MENU_FULLSCREEN); }
- (void)openHelp:(id)sender {
    (void)sender;
    [[NSWorkspace sharedWorkspace] openURL:[NSURL URLWithString:@"https://github.com/debpalash/Opal"]];
}
@end

static NSMenuItem *opal_item(NSString *title, SEL action, NSString *key, id target) {
    NSMenuItem *item = [[NSMenuItem alloc] initWithTitle:title action:action keyEquivalent:key ?: @""];
    if (target) item.target = target;
    return item;
}

static void opal_add_menu(NSMenu *bar, NSString *title, NSMenu *submenu) {
    NSMenuItem *root = [[NSMenuItem alloc] initWithTitle:title action:nil keyEquivalent:@""];
    root.submenu = submenu;
    [bar addItem:root];
}

void opal_app_menu_init(void) {
    static BOOL initialized = NO;
    if (initialized) return;
    initialized = YES;

    @autoreleasepool {
        static OpalMenuTarget *target;
        target = [OpalMenuTarget new];
        NSMenu *bar = [NSMenu new];

        NSMenu *app = [[NSMenu alloc] initWithTitle:@"Opal"];
        [app addItem:opal_item(@"About Opal", @selector(orderFrontStandardAboutPanel:), @"", nil)];
        [app addItem:[NSMenuItem separatorItem]];
        [app addItem:opal_item(@"Settings…", @selector(openSettings:), @",", target)];
        [app addItem:[NSMenuItem separatorItem]];
        NSMenu *services = [[NSMenu alloc] initWithTitle:@"Services"];
        NSMenuItem *servicesItem = opal_item(@"Services", nil, @"", nil);
        servicesItem.submenu = services;
        [app addItem:servicesItem];
        [NSApp setServicesMenu:services];
        [app addItem:[NSMenuItem separatorItem]];
        [app addItem:opal_item(@"Hide Opal", @selector(hide:), @"h", nil)];
        NSMenuItem *hideOthers = opal_item(@"Hide Others", @selector(hideOtherApplications:), @"h", nil);
        hideOthers.keyEquivalentModifierMask = NSEventModifierFlagCommand | NSEventModifierFlagOption;
        [app addItem:hideOthers];
        [app addItem:opal_item(@"Show All", @selector(unhideAllApplications:), @"", nil)];
        [app addItem:[NSMenuItem separatorItem]];
        [app addItem:opal_item(@"Quit Opal", @selector(terminate:), @"q", nil)];
        opal_add_menu(bar, @"Opal", app);

        NSMenu *file = [[NSMenu alloc] initWithTitle:@"File"];
        [file addItem:opal_item(@"Open…", @selector(openFile:), @"o", target)];
        [file addItem:[NSMenuItem separatorItem]];
        [file addItem:opal_item(@"Close Window", @selector(performClose:), @"w", nil)];
        opal_add_menu(bar, @"File", file);

        NSMenu *edit = [[NSMenu alloc] initWithTitle:@"Edit"];
        [edit addItem:opal_item(@"Undo", @selector(undo:), @"z", nil)];
        NSMenuItem *redo = opal_item(@"Redo", @selector(redo:), @"Z", nil);
        redo.keyEquivalentModifierMask = NSEventModifierFlagCommand | NSEventModifierFlagShift;
        [edit addItem:redo];
        [edit addItem:[NSMenuItem separatorItem]];
        [edit addItem:opal_item(@"Cut", @selector(cut:), @"x", nil)];
        [edit addItem:opal_item(@"Copy", @selector(copy:), @"c", nil)];
        [edit addItem:opal_item(@"Paste", @selector(paste:), @"v", nil)];
        [edit addItem:opal_item(@"Select All", @selector(selectAll:), @"a", nil)];
        opal_add_menu(bar, @"Edit", edit);

        NSMenu *view = [[NSMenu alloc] initWithTitle:@"View"];
        [view addItem:opal_item(@"Home", @selector(showHome:), @"1", target)];
        [view addItem:opal_item(@"Search", @selector(showSearch:), @"f", target)];
        [view addItem:opal_item(@"Browse", @selector(showBrowse:), @"2", target)];
        [view addItem:[NSMenuItem separatorItem]];
        NSMenuItem *fullscreen = opal_item(@"Toggle Full Screen", @selector(toggleOpalFullscreen:), @"f", target);
        fullscreen.keyEquivalentModifierMask = NSEventModifierFlagCommand | NSEventModifierFlagControl;
        [view addItem:fullscreen];
        opal_add_menu(bar, @"View", view);

        NSMenu *playback = [[NSMenu alloc] initWithTitle:@"Playback"];
        [playback addItem:opal_item(@"Play/Pause", @selector(playPause:), @" ", target)];
        [playback addItem:opal_item(@"Jump Back 10 Seconds", @selector(seekBack:), @"[", target)];
        [playback addItem:opal_item(@"Jump Forward 10 Seconds", @selector(seekForward:), @"]", target)];
        opal_add_menu(bar, @"Playback", playback);

        NSMenu *window = [[NSMenu alloc] initWithTitle:@"Window"];
        [window addItem:opal_item(@"Minimize", @selector(performMiniaturize:), @"m", nil)];
        [window addItem:opal_item(@"Zoom", @selector(performZoom:), @"", nil)];
        [window addItem:[NSMenuItem separatorItem]];
        [window addItem:opal_item(@"Bring All to Front", @selector(arrangeInFront:), @"", nil)];
        opal_add_menu(bar, @"Window", window);
        [NSApp setWindowsMenu:window];

        NSMenu *help = [[NSMenu alloc] initWithTitle:@"Help"];
        [help addItem:opal_item(@"Opal Help", @selector(openHelp:), @"?", target)];
        opal_add_menu(bar, @"Help", help);
        [NSApp setHelpMenu:help];

        NSApp.mainMenu = bar;
    }
}
