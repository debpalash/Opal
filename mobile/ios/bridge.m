#import <UIKit/UIKit.h>
#import <AVFoundation/AVFoundation.h>
#import <UniformTypeIdentifiers/UniformTypeIdentifiers.h>
#import <WebKit/WebKit.h>
#import <ImageIO/ImageIO.h>
#include <SDL3/SDL.h>
#include <stdio.h>
#include <sqlite3.h>
void opal_ios_prepare_environment(void) {
    // Immersive: the home indicator fades out until the bottom edge is touched.
    SDL_SetHint(SDL_HINT_IOS_HIDE_HOME_INDICATOR, "1");
    NSFileManager *files = NSFileManager.defaultManager;
    NSURL *support = [files URLsForDirectory:NSApplicationSupportDirectory inDomains:NSUserDomainMask].firstObject;
    NSURL *cache = [files URLsForDirectory:NSCachesDirectory inDomains:NSUserDomainMask].firstObject;
    NSURL *config = [support URLByAppendingPathComponent:@"opal" isDirectory:YES];
    [files createDirectoryAtURL:config withIntermediateDirectories:YES attributes:@{NSFileProtectionKey:NSFileProtectionCompleteUntilFirstUserAuthentication} error:nil];
    // Torrents keep writing while the phone is locked (background audio):
    // downloads must not use the "Complete" class, which denies I/O when locked.
    NSURL *downloads = [[files URLsForDirectory:NSDocumentDirectory inDomains:NSUserDomainMask].firstObject URLByAppendingPathComponent:@"Downloads" isDirectory:YES];
    [files createDirectoryAtURL:downloads withIntermediateDirectories:YES attributes:@{NSFileProtectionKey:NSFileProtectionCompleteUntilFirstUserAuthentication} error:nil];
    [files setAttributes:@{NSFileProtectionKey:NSFileProtectionCompleteUntilFirstUserAuthentication} ofItemAtPath:downloads.path error:nil];
    setenv("XDG_CONFIG_HOME", support.path.UTF8String, 1);
    setenv("XDG_CACHE_HOME", cache.path.UTF8String, 1);
    NSURL *legacy = [support URLByAppendingPathComponent:@"opal.db"];
    NSURL *current = [config URLByAppendingPathComponent:@"opal.db"];
    if ([files fileExistsAtPath:legacy.path] && ![files fileExistsAtPath:current.path]) {
        sqlite3 *from = NULL, *to = NULL;
        if (sqlite3_open_v2(legacy.path.UTF8String, &from, SQLITE_OPEN_READONLY, NULL) == SQLITE_OK && sqlite3_open(current.path.UTF8String, &to) == SQLITE_OK) {
            sqlite3_backup *backup = sqlite3_backup_init(to, "main", from, "main");
            if (backup) { sqlite3_backup_step(backup, -1); sqlite3_backup_finish(backup); }
        }
        if (from) sqlite3_close(from);
        if (to) sqlite3_close(to);
    }
}
// Read from worker threads (TLS setup): copy once, never an autoreleased pointer.
const char *opal_ios_resource_dir(void) {
    static char *dir; static dispatch_once_t once;
    dispatch_once(&once, ^{ @autoreleasepool { dir = strdup(NSBundle.mainBundle.resourcePath.fileSystemRepresentation ?: ""); } });
    return dir;
}
void opal_ios_log(const unsigned char *bytes, size_t len) { fwrite(bytes, 1, len, stderr); fputc('\n', stderr); fflush(stderr); }
void opal_ios_metadata(void) { SDL_SetAppMetadata("Opal", "0.1.0", "com.debpalash.opal.ios"); }

// ImageIO supplies the shared image decoder's WebP seam on iOS.
int opal_webp_info(const unsigned char *bytes, size_t length, int *width, int *height) {
    CGImageSourceRef source = CGImageSourceCreateWithData((__bridge CFDataRef)[NSData dataWithBytesNoCopy:(void *)bytes length:length freeWhenDone:NO], NULL);
    if (!source) return 0;
    NSDictionary *properties = CFBridgingRelease(CGImageSourceCopyPropertiesAtIndex(source, 0, NULL));
    CFRelease(source);
    NSNumber *w = properties[(NSString *)kCGImagePropertyPixelWidth], *h = properties[(NSString *)kCGImagePropertyPixelHeight];
    if (w.longLongValue <= 0 || h.longLongValue <= 0 || w.longLongValue > INT_MAX || h.longLongValue > INT_MAX) return 0;
    *width = w.intValue; *height = h.intValue; return 1;
}
unsigned char *opal_webp_decode_rgba(const unsigned char *bytes, size_t length, int width, int height, size_t rgba_bytes) {
    if (width <= 0 || height <= 0 || (uint64_t)width * height * 4 != rgba_bytes) return NULL;
    CGImageSourceRef source = CGImageSourceCreateWithData((__bridge CFDataRef)[NSData dataWithBytesNoCopy:(void *)bytes length:length freeWhenDone:NO], NULL);
    if (!source) return NULL;
    CGImageRef image = CGImageSourceCreateImageAtIndex(source, 0, NULL);
    CFRelease(source);
    if (!image) return NULL;
    if (CGImageGetWidth(image) != width || CGImageGetHeight(image) != height) { CGImageRelease(image); return NULL; }
    unsigned char *pixels = calloc(1, rgba_bytes);
    CGColorSpaceRef color = CGColorSpaceCreateDeviceRGB();
    CGContextRef context = pixels ? CGBitmapContextCreate(pixels, width, height, 8, width * 4, color, kCGImageAlphaPremultipliedLast | kCGBitmapByteOrder32Big) : NULL;
    CGColorSpaceRelease(color);
    if (!context) { free(pixels); CGImageRelease(image); return NULL; }
    CGContextDrawImage(context, CGRectMake(0, 0, width, height), image);
    CGContextRelease(context); CGImageRelease(image);
    for (size_t i = 0; i < rgba_bytes; i += 4) {
        unsigned alpha = pixels[i + 3];
        if (alpha && alpha < 255) for (size_t channel = 0; channel < 3; ++channel) pixels[i + channel] = MIN(255, (pixels[i + channel] * 255 + alpha / 2) / alpha);
    }
    return pixels;
}

static NSString *status_text = @"Ready to play";
static BOOL smoke_test;
static void wake_ui(void) { SDL_Event event = { .type = SDL_EVENT_USER }; SDL_PushEvent(&event); }
static UIWindow *app_window(void) {
    for (UIScene *scene in UIApplication.sharedApplication.connectedScenes) {
        if (![scene isKindOfClass:UIWindowScene.class]) continue;
        for (UIWindow *window in ((UIWindowScene *)scene).windows) if (window.isKeyWindow) return window;
    }
    // SDL also supports UIKit's legacy app-delegate lifecycle.
    for (UIWindow *window in UIApplication.sharedApplication.windows) if (window.isKeyWindow) return window;
    return nil;
}
static UIViewController *presenter(void) {
    UIViewController *root = app_window().rootViewController;
    while (root.presentedViewController && !root.presentedViewController.isBeingDismissed) root = root.presentedViewController;
    return root;
}
static void set_status(NSString *value) { status_text = value; wake_ui(); }
static void play(NSURL *url) {
    extern bool opal_ios_valid_media_url(const char *raw);
    if (!url || (!url.isFileURL && !opal_ios_valid_media_url(url.absoluteString.UTF8String)) || url.user.length || url.password.length) {
        set_status(@"Enter a valid media URL."); return;
    }
    extern bool opal_ios_open_media(const char *raw);
    NSError *audio_error = nil;
    [AVAudioSession.sharedInstance setCategory:AVAudioSessionCategoryPlayback mode:AVAudioSessionModeMoviePlayback options:0 error:&audio_error];
    [AVAudioSession.sharedInstance setActive:YES error:&audio_error];
    if (audio_error) { set_status(@"Could not open audio output."); return; }
    const char *location = url.isFileURL ? url.path.UTF8String : url.absoluteString.UTF8String;
    if (!opal_ios_open_media(location)) { set_status(@"Could not open media."); return; }
    set_status(@"Playing");
    if (smoke_test) dispatch_after(dispatch_time(DISPATCH_TIME_NOW, 5 * NSEC_PER_SEC), dispatch_get_main_queue(), ^{
        extern bool opal_ios_player_probe(double *time, bool *video);
        double time = 0; bool video = false;
        bool ok = opal_ios_player_probe(&time, &video);
        fprintf(stderr, "OPAL_IOS_SHARED_PLAYER_%s time=%.2f texture=%d\n", ok ? "OK" : "FAILED", time, video); fflush(stderr);
    });

}
void opal_ios_safe_area(float *top, float *bottom, float *left, float *right, float *keyboard) {
    static CGFloat keyboard_overlap;
    static id observer;
    if (!observer) observer = [NSNotificationCenter.defaultCenter addObserverForName:UIKeyboardWillChangeFrameNotification object:nil queue:NSOperationQueue.mainQueue usingBlock:^(NSNotification *notification) {
        UIWindow *window = app_window();
        CGRect frame = [window convertRect:[notification.userInfo[UIKeyboardFrameEndUserInfoKey] CGRectValue] fromCoordinateSpace:window.windowScene.screen.coordinateSpace];
        CGRect overlap = CGRectIntersection(window.bounds, frame);
        keyboard_overlap = CGRectIsNull(overlap) ? 0 : overlap.size.height;
        wake_ui();
    }];
    UIEdgeInsets insets = app_window().safeAreaInsets;
    *top = insets.top; *bottom = MAX(insets.bottom, keyboard_overlap); *left = insets.left; *right = insets.right;
    *keyboard = keyboard_overlap;
}
// UI walk: rotate the scene like the user turning the phone.
void opal_ios_set_landscape(bool landscape) {
    UIWindowScene *scene = app_window().windowScene;
    UIInterfaceOrientationMask mask = landscape ? UIInterfaceOrientationMaskLandscapeRight : UIInterfaceOrientationMaskPortrait;
    [app_window().rootViewController setNeedsUpdateOfSupportedInterfaceOrientations];
    [scene requestGeometryUpdateWithPreferences:[[UIWindowSceneGeometryPreferencesIOS alloc] initWithInterfaceOrientations:mask] errorHandler:^(NSError *error) {
        fprintf(stderr, "opal: rotate failed: %s\n", error.localizedDescription.UTF8String);
    }];
}
void opal_ios_open_demo(void) { play([NSBundle.mainBundle URLForResource:@"OpalPreview" withExtension:@"mp4"]); }

@interface OpalDocuments : NSObject <UIDocumentPickerDelegate>
@end
static OpalDocuments *documents;
@implementation OpalDocuments
- (void)documentPicker:(UIDocumentPickerViewController *)controller didPickDocumentsAtURLs:(NSArray<NSURL *> *)urls {
    NSURL *source = urls.firstObject; if (!source) return;
    BOOL scoped = [source startAccessingSecurityScopedResource];
    set_status(@"Importing media…");
    dispatch_async(dispatch_get_global_queue(QOS_CLASS_USER_INITIATED, 0), ^{
        NSFileManager *files = NSFileManager.defaultManager;
        NSURL *directory = [[files URLsForDirectory:NSDocumentDirectory inDomains:NSUserDomainMask].firstObject URLByAppendingPathComponent:@"Media" isDirectory:YES];
        [files createDirectoryAtURL:directory withIntermediateDirectories:YES attributes:@{NSFileProtectionKey:NSFileProtectionCompleteUntilFirstUserAuthentication} error:nil];
        NSURL *target = [directory URLByAppendingPathComponent:[NSString stringWithFormat:@"%@-%@", NSUUID.UUID.UUIDString, source.lastPathComponent]];
        NSError *error = nil; BOOL copied = [files copyItemAtURL:source toURL:target error:&error];
        if (scoped) [source stopAccessingSecurityScopedResource];
        dispatch_async(dispatch_get_main_queue(), ^{ if (copied) play(target); else set_status(@"Could not import this file. Try another file."); });
    });
}
- (void)documentPickerWasCancelled:(UIDocumentPickerViewController *)controller { set_status(@"Ready to play"); }
@end
void opal_ios_import(void) {
    if (!documents) documents = [OpalDocuments new];
    UIDocumentPickerViewController *picker = [[UIDocumentPickerViewController alloc] initForOpeningContentTypes:@[UTTypeMovie, UTTypeAudio, UTTypePDF, UTTypeEPUB, UTTypeZIP, UTTypePlaylist,
        [UTType typeWithFilenameExtension:@"torrent"] ?: UTTypeData, [UTType typeWithFilenameExtension:@"cbz"] ?: UTTypeZIP,
        [UTType typeWithFilenameExtension:@"cbr"] ?: UTTypeData] asCopy:YES];
    picker.delegate = documents; picker.allowsMultipleSelection = NO;
    [presenter() presentViewController:picker animated:YES completion:nil];
}
bool opal_ios_ui_test(void) {
    static int cached = -1;
    if (cached < 0) cached = [NSProcessInfo.processInfo.arguments containsObject:@"--ui-test"];
    return cached;
}
void opal_ios_ready(void) {
    extern void opal_ios_background(void);
    [NSNotificationCenter.defaultCenter addObserverForName:UIApplicationDidEnterBackgroundNotification object:nil queue:NSOperationQueue.mainQueue usingBlock:^(NSNotification *note) { opal_ios_background(); }];
    fprintf(stderr, "OPAL_IOS_UI_READY Zig/DVUI device build\n"); fflush(stderr);
    smoke_test = [NSProcessInfo.processInfo.arguments containsObject:@"--smoke-test"];
    if (smoke_test) dispatch_after(dispatch_time(DISPATCH_TIME_NOW, NSEC_PER_SEC), dispatch_get_main_queue(), ^{ opal_ios_open_demo(); });
}


void opal_ios_open_link(void) {
    UIAlertController *dialog = [UIAlertController alertControllerWithTitle:@"Play a link" message:@"Open a compatible video or audio URL." preferredStyle:UIAlertControllerStyleAlert];
    [dialog addTextFieldWithConfigurationHandler:^(UITextField *field) { field.placeholder = @"https://…"; field.keyboardType = UIKeyboardTypeURL; field.autocapitalizationType = UITextAutocapitalizationTypeNone; field.autocorrectionType = UITextAutocorrectionTypeNo; }];
    [dialog addAction:[UIAlertAction actionWithTitle:@"Cancel" style:UIAlertActionStyleCancel handler:nil]];
    [dialog addAction:[UIAlertAction actionWithTitle:@"Play" style:UIAlertActionStyleDefault handler:^(UIAlertAction *action) {
        NSString *value = dialog.textFields.firstObject.text;
        dispatch_async(dispatch_get_main_queue(), ^{ play([NSURL URLWithString:[value stringByTrimmingCharactersInSet:NSCharacterSet.whitespaceAndNewlineCharacterSet]]); });
    }]];
    [presenter() presentViewController:dialog animated:YES completion:nil];
}
