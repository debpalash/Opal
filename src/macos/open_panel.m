// App-owned macOS media chooser. AppleScript's `choose file` runs in a
// separate process, which can restore a tiny icon-only window and lose the
// normal navigation and Cancel/Open controls.

#import <AppKit/AppKit.h>
#include <stddef.h>
#include <string.h>

static NSOpenPanel *g_open_panel;
static char g_selected_path[4096];
static size_t g_selected_path_len;

static void opal_finish_open_panel(NSModalResponse response) {
    if (response == NSModalResponseOK) {
        const char *path = g_open_panel.URL.path.fileSystemRepresentation;
        if (path) {
            const size_t length = strnlen(path, sizeof(g_selected_path) - 1);
            memcpy(g_selected_path, path, length);
            g_selected_path[length] = '\0';
            g_selected_path_len = length;
        }
    }
    g_open_panel = nil;
}

void opal_open_panel_show(void) {
    dispatch_async(dispatch_get_main_queue(), ^{
        if (g_open_panel) {
            [g_open_panel makeKeyAndOrderFront:nil];
            return;
        }

        NSOpenPanel *panel = [NSOpenPanel openPanel];
        g_open_panel = panel;
        panel.title = @"Open Media";
        panel.message = @"Choose a video, audio file, or playlist.";
        panel.prompt = @"Open";
        panel.canChooseFiles = YES;
        panel.canChooseDirectories = NO;
        panel.allowsMultipleSelection = NO;
        panel.resolvesAliases = YES;
        panel.treatsFilePackagesAsDirectories = NO;
        panel.contentMinSize = NSMakeSize(720.0, 460.0);
        NSSize size = panel.contentView.bounds.size;
        size.width = MAX(size.width, 720.0);
        size.height = MAX(size.height, 460.0);
        [panel setContentSize:size];

        [NSApp activateIgnoringOtherApps:YES];
        NSWindow *owner = NSApp.keyWindow ?: NSApp.mainWindow;
        if (owner) {
            [panel beginSheetModalForWindow:owner completionHandler:^(NSModalResponse response) {
                opal_finish_open_panel(response);
            }];
        } else {
            [panel beginWithCompletionHandler:^(NSModalResponse response) {
                opal_finish_open_panel(response);
            }];
        }
    });
}

size_t opal_open_panel_take(char *output, size_t capacity) {
    if (!output || capacity == 0 || g_selected_path_len == 0) return 0;
    const size_t length = g_selected_path_len < capacity - 1
        ? g_selected_path_len
        : capacity - 1;
    memcpy(output, g_selected_path, length);
    output[length] = '\0';
    g_selected_path_len = 0;
    g_selected_path[0] = '\0';
    return length;
}
