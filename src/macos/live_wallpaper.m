// A non-activating, click-through desktop surface on each connected display.
#import <AppKit/AppKit.h>
#import <AVFoundation/AVFoundation.h>
#import <QuartzCore/QuartzCore.h>
#import <CoreGraphics/CoreGraphics.h>
@interface OpalDesktopWindow : NSWindow
@end
@implementation OpalDesktopWindow
- (BOOL)canBecomeKeyWindow { return NO; }
- (BOOL)canBecomeMainWindow { return NO; }
@end
static NSMutableArray<NSWindow *> *windows;
static NSMutableArray<AVQueuePlayer *> *players;
static NSMutableArray<AVPlayerLooper *> *loopers;
static id display_observer;
static NSURL *current_url;
static BOOL fill_screen;
static void position_surfaces(void);
void opal_wallpaper_stop(void) {
    if (display_observer) [NSNotificationCenter.defaultCenter removeObserver:display_observer];
    display_observer = nil;
    for (AVPlayerLooper *looper in loopers) [looper disableLooping];
    for (AVQueuePlayer *player in players) { [player pause]; [player removeAllItems]; }
    for (NSWindow *window in windows) { [window orderOut:nil]; [window close]; }
    windows = nil; players = nil; loopers = nil; current_url = nil;
}
static void position_surfaces(void) {
    for (AVPlayerLooper *looper in loopers) [looper disableLooping];
    for (AVQueuePlayer *player in players) { [player pause]; [player removeAllItems]; }
    for (NSWindow *window in windows) { [window orderOut:nil]; [window close]; }
    windows = [NSMutableArray new]; players = [NSMutableArray new]; loopers = [NSMutableArray new];
    for (NSScreen *screen in NSScreen.screens) {
        OpalDesktopWindow *window = [[OpalDesktopWindow alloc] initWithContentRect:screen.frame styleMask:NSWindowStyleMaskBorderless backing:NSBackingStoreBuffered defer:NO screen:screen];
        [window setFrame:screen.frame display:NO];
        window.releasedWhenClosed = NO;
        window.level = CGWindowLevelForKey(kCGDesktopWindowLevelKey) + 1;
        window.collectionBehavior = NSWindowCollectionBehaviorCanJoinAllSpaces | NSWindowCollectionBehaviorStationary | NSWindowCollectionBehaviorIgnoresCycle;
        window.ignoresMouseEvents = YES; window.hidesOnDeactivate = NO; window.hasShadow = NO;
        window.backgroundColor = NSColor.blackColor;
        window.contentView.wantsLayer = YES;
        AVQueuePlayer *player = [AVQueuePlayer queuePlayerWithItems:@[]]; player.muted = YES;
        AVPlayerItem *item = [AVPlayerItem playerItemWithURL:current_url];
        AVPlayerLooper *looper = [AVPlayerLooper playerLooperWithPlayer:player templateItem:item];
        AVPlayerLayer *layer = [AVPlayerLayer playerLayerWithPlayer:player];
        layer.videoGravity = fill_screen ? AVLayerVideoGravityResizeAspectFill : AVLayerVideoGravityResizeAspect;
        layer.frame = window.contentView.bounds; layer.autoresizingMask = kCALayerWidthSizable | kCALayerHeightSizable;
        [window.contentView.layer addSublayer:layer];
        [windows addObject:window]; [players addObject:player]; [loopers addObject:looper];
        [window orderBack:nil]; [player play];
    }
}
int opal_wallpaper_start(const char *path, int fill) {
    opal_wallpaper_stop();
    NSString *file = [NSString stringWithUTF8String:path];
    if (!file || ![NSFileManager.defaultManager fileExistsAtPath:file] || NSScreen.screens.count == 0) return 0;
    current_url = [NSURL fileURLWithPath:file]; fill_screen = fill;
    position_surfaces();
    display_observer = [NSNotificationCenter.defaultCenter addObserverForName:NSApplicationDidChangeScreenParametersNotification object:nil queue:NSOperationQueue.mainQueue usingBlock:^(NSNotification *note) { position_surfaces(); }];
    return windows.count > 0;
}
// 0 = preparing, 1 = ready on every display, -1 = decoding failed.
int opal_wallpaper_status(void) {
    if (!windows.count) return -1;
    BOOL ready = YES;
    for (NSUInteger i = 0; i < players.count; ++i) {
        if (players[i].status == AVPlayerStatusFailed || loopers[i].status == AVPlayerLooperStatusFailed || players[i].currentItem.status == AVPlayerItemStatusFailed) return -1;
        AVPlayerLayer *layer = (AVPlayerLayer *)windows[i].contentView.layer.sublayers.firstObject;
        if (players[i].currentItem.status != AVPlayerItemStatusReadyToPlay || !layer.readyForDisplay) ready = NO;
    }
    return ready ? 1 : 0;
}
int opal_wallpaper_test_desktop(void) {
    if (windows.count != NSScreen.screens.count || !windows.count) return 0;
    for (NSUInteger i = 0; i < windows.count; ++i) {
        NSWindow *w = windows[i];
        if (w.level <= CGWindowLevelForKey(kCGDesktopWindowLevelKey) || w.level >= CGWindowLevelForKey(kCGDesktopIconWindowLevelKey) || w.canBecomeKeyWindow || !w.ignoresMouseEvents || !NSEqualRects(w.frame, NSScreen.screens[i].frame) || !players[i].muted) return 0;
    }
    return 1;
}
