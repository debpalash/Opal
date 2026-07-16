// Native macOS Now Playing + hardware media keys.
//
// MPNowPlayingInfoCenter publishes the current track to Control Center / the
// lock screen / AirPods, and MPRemoteCommandCenter receives the hardware
// media keys (F7/F8/F9, headphone buttons, Control Center transport).
//
// Threading contract: the command handlers NEVER call into Zig. They enqueue
// small {cmd, arg} records into a pthread_mutex-protected ring that the UI
// thread drains once per frame via opal_media_remote_poll() (see
// src/player/media_remote.zig). Handlers run on the main queue, but the queue
// is safe from any thread regardless.

#import <Foundation/Foundation.h>
#import <MediaPlayer/MediaPlayer.h>
#include <pthread.h>

// Command codes — MUST stay in sync with Command in
// src/player/media_remote_pure.zig (the Zig side decodes these).
enum {
    OPAL_MR_CMD_NONE = 0,
    OPAL_MR_CMD_PLAY = 1,
    OPAL_MR_CMD_PAUSE = 2,
    OPAL_MR_CMD_TOGGLE = 3,
    OPAL_MR_CMD_SEEK_ABSOLUTE = 4, // arg = target position, seconds
    OPAL_MR_CMD_SEEK_RELATIVE = 5, // arg = signed delta, seconds
};

#define OPAL_MR_QUEUE_CAP 16

typedef struct {
    int cmd;
    double arg;
} opal_mr_cmd_t;

static pthread_mutex_t g_q_lock = PTHREAD_MUTEX_INITIALIZER;
static opal_mr_cmd_t g_queue[OPAL_MR_QUEUE_CAP];
static int g_q_head = 0; // next slot to read
static int g_q_count = 0;
static int g_inited = 0;

static void opal_mr_push(int cmd, double arg) {
    pthread_mutex_lock(&g_q_lock);
    if (g_q_count == OPAL_MR_QUEUE_CAP) {
        // Full: drop the oldest — a stale media-key press is worthless.
        g_q_head = (g_q_head + 1) % OPAL_MR_QUEUE_CAP;
        g_q_count--;
    }
    int tail = (g_q_head + g_q_count) % OPAL_MR_QUEUE_CAP;
    g_queue[tail].cmd = cmd;
    g_queue[tail].arg = arg;
    g_q_count++;
    pthread_mutex_unlock(&g_q_lock);
}

// Poll one pending remote command. Returns the command code (OPAL_MR_CMD_NONE
// when the queue is empty) and writes the argument (seek seconds) to *arg_out.
int opal_media_remote_poll(double *arg_out) {
    int cmd = OPAL_MR_CMD_NONE;
    double arg = 0.0;
    pthread_mutex_lock(&g_q_lock);
    if (g_q_count > 0) {
        cmd = g_queue[g_q_head].cmd;
        arg = g_queue[g_q_head].arg;
        g_q_head = (g_q_head + 1) % OPAL_MR_QUEUE_CAP;
        g_q_count--;
    }
    pthread_mutex_unlock(&g_q_lock);
    if (arg_out) *arg_out = arg;
    return cmd;
}

// Register the MPRemoteCommandCenter handlers. Called once, lazily, when
// playback first starts — macOS only routes media keys to apps that have set
// a playbackState (opal_nowplaying_update does that), so registering earlier
// would be pointless and registering here keeps us out of the media-key
// routing until we actually play something.
void opal_media_remote_init(void) {
    if (g_inited) return;
    g_inited = 1;
    @autoreleasepool {
        MPRemoteCommandCenter *cc = [MPRemoteCommandCenter sharedCommandCenter];

        [cc.playCommand addTargetWithHandler:^MPRemoteCommandHandlerStatus(MPRemoteCommandEvent *event) {
            (void)event;
            opal_mr_push(OPAL_MR_CMD_PLAY, 0.0);
            return MPRemoteCommandHandlerStatusSuccess;
        }];
        [cc.pauseCommand addTargetWithHandler:^MPRemoteCommandHandlerStatus(MPRemoteCommandEvent *event) {
            (void)event;
            opal_mr_push(OPAL_MR_CMD_PAUSE, 0.0);
            return MPRemoteCommandHandlerStatusSuccess;
        }];
        [cc.togglePlayPauseCommand addTargetWithHandler:^MPRemoteCommandHandlerStatus(MPRemoteCommandEvent *event) {
            (void)event;
            opal_mr_push(OPAL_MR_CMD_TOGGLE, 0.0);
            return MPRemoteCommandHandlerStatusSuccess;
        }];

        // Control Center scrubber drag → absolute seek.
        [cc.changePlaybackPositionCommand addTargetWithHandler:^MPRemoteCommandHandlerStatus(MPRemoteCommandEvent *event) {
            MPChangePlaybackPositionCommandEvent *e = (MPChangePlaybackPositionCommandEvent *)event;
            opal_mr_push(OPAL_MR_CMD_SEEK_ABSOLUTE, e.positionTime);
            return MPRemoteCommandHandlerStatusSuccess;
        }];

        // 10s skip buttons (shown when next/previous track are unhandled).
        cc.skipForwardCommand.preferredIntervals = @[ @(10.0) ];
        [cc.skipForwardCommand addTargetWithHandler:^MPRemoteCommandHandlerStatus(MPRemoteCommandEvent *event) {
            MPSkipIntervalCommandEvent *e = (MPSkipIntervalCommandEvent *)event;
            double interval = e.interval > 0 ? e.interval : 10.0;
            opal_mr_push(OPAL_MR_CMD_SEEK_RELATIVE, interval);
            return MPRemoteCommandHandlerStatusSuccess;
        }];
        cc.skipBackwardCommand.preferredIntervals = @[ @(10.0) ];
        [cc.skipBackwardCommand addTargetWithHandler:^MPRemoteCommandHandlerStatus(MPRemoteCommandEvent *event) {
            MPSkipIntervalCommandEvent *e = (MPSkipIntervalCommandEvent *)event;
            double interval = e.interval > 0 ? e.interval : 10.0;
            opal_mr_push(OPAL_MR_CMD_SEEK_RELATIVE, -interval);
            return MPRemoteCommandHandlerStatusSuccess;
        }];
    }
}

// Push current track metadata + transport state to the system Now Playing
// card. rate: 0.0 paused, 1.0 playing — macOS advances the displayed elapsed
// time at `rate` between pushes, so a ~1s push cadence stays smooth.
void opal_nowplaying_update(const char *title, const char *artist,
                            double duration_s, double position_s, double rate) {
    @autoreleasepool {
        NSMutableDictionary *info = [NSMutableDictionary dictionary];
        if (title && title[0]) {
            NSString *t = [NSString stringWithUTF8String:title];
            if (t) info[MPMediaItemPropertyTitle] = t;
        }
        if (artist && artist[0]) {
            NSString *a = [NSString stringWithUTF8String:artist];
            if (a) info[MPMediaItemPropertyArtist] = a;
        }
        if (duration_s > 0) {
            info[MPMediaItemPropertyPlaybackDuration] = @(duration_s);
        }
        info[MPNowPlayingInfoPropertyElapsedPlaybackTime] = @(position_s);
        info[MPNowPlayingInfoPropertyPlaybackRate] = @(rate);

        MPNowPlayingInfoCenter *center = [MPNowPlayingInfoCenter defaultCenter];
        center.nowPlayingInfo = info;
        // Setting playbackState is what makes macOS route media keys to us.
        center.playbackState = (rate > 0.0) ? MPNowPlayingPlaybackStatePlaying
                                            : MPNowPlayingPlaybackStatePaused;
    }
}

// Drop the Now Playing card (player closed / app exit).
void opal_nowplaying_clear(void) {
    @autoreleasepool {
        MPNowPlayingInfoCenter *center = [MPNowPlayingInfoCenter defaultCenter];
        center.playbackState = MPNowPlayingPlaybackStateStopped;
        center.nowPlayingInfo = nil;
    }
}
