//! Live-ASR capture (experimental, WIP) — transcribe PLAYBACK audio into the
//! Co-Watcher dialogue ring + Total Recall scene memories so they work on
//! content WITHOUT subtitles (foreign / live / un-subtitled).
//!
//! BLOCKER (needs a product decision): capturing mpv's OUTPUT audio requires a
//! system audio LOOPBACK device — BlackHole (macOS) or a PulseAudio monitor
//! source (Linux). The app's existing capture (ai_voice) uses avfoundation ":0",
//! which is the MICROPHONE/INPUT — recording that would feed ROOM NOISE (and
//! Whisper hallucinations) into the memory system, not the show's dialogue.
//!
//! Therefore this module is intentionally OFF by default and, when enabled
//! without a configured loopback device, it is a NO-OP that logs guidance —
//! it deliberately does NOT fall back to the mic. Once the loopback approach is
//! chosen, the worker will capture that device in ~10s chunks via ffmpeg,
//! transcribe through the existing STT server, and feed non-empty text to
//! scene_memory.ingestScene + the co_watch dialogue ring.

const std = @import("std");
const logs = @import("../core/logs.zig");
const state = @import("../core/state.zig");

var running: std.atomic.Value(bool) = std.atomic.Value(bool).init(false);

/// Wired from the settings toggle / config restore. Reflects the flag into
/// state and starts/stops the capture worker.
pub fn setEnabled(on: bool) void {
    state.app.live_asr_enabled = on;
    if (on) start() else stop();
}

pub fn start() void {
    if (running.swap(true, .acq_rel)) return; // already running
    if (std.Thread.spawn(.{}, worker, .{})) |t| t.detach() else |_| {
        running.store(false, .release);
    }
}

pub fn stop() void {
    running.store(false, .release);
}

fn worker() void {
    defer running.store(false, .release);
    // SAFE no-op until an audio-loopback device is wired (see file header).
    // We must NOT capture the default mic — that records room noise, not the
    // playback, and would poison Total Recall / the Co-Watcher dialogue ring.
    logs.pushLog(
        "warn",
        "live-asr",
        "Live-ASR is experimental and needs an audio loopback device " ++
            "(BlackHole on macOS / a PulseAudio monitor on Linux). Capture is " ++
            "pending that setup; enabling it is currently a safe no-op.",
        false,
    );
}
