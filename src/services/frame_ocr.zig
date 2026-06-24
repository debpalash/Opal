//! frame_ocr.zig — OCR the active player's current video frame.
//!
//! Reuses the native PP-OCRv5 ONNX pipeline (the same C wrapper that
//! src/services/comics.zig drives). The mpv software renderer fills the
//! player's pixel buffer at a fixed `player.video_w` x `player.video_h`
//! surface (the video is letterboxed inside it), so those are the real
//! dimensions of the RGBA frame. Frames are opaque, so the premultiplied
//! `dvui.Color.PMA` bytes are byte-identical to straight RGBA — we can
//! cast the pixel pointer straight through to the C wrapper.
//!
//! Robustness contract: never crash; return 0 on any problem (no active
//! player, buffer not ready, OCR init failure, OCR unavailable).

const std = @import("std");
const dvui = @import("dvui");
const state = @import("../core/state.zig");
const logs = @import("../core/logs.zig");
const player = @import("../player/player.zig");
const sync = @import("../core/sync.zig");
const alloc = @import("../core/alloc.zig");

// Native ONNX Runtime OCR via the same C wrapper comics.zig uses.
const ocr_c = @cImport({
    @cInclude("ocr_ort.h");
});

var ocr_initialized: std.atomic.Value(bool) = std.atomic.Value(bool).init(false);
var ocr_init_failed: std.atomic.Value(bool) = std.atomic.Value(bool).init(false);
var ocr_init_lock: std.atomic.Value(bool) = std.atomic.Value(bool).init(false);

// Module-owned scratch buffer. mpv writes p.pixels on the render thread while
// OCR runs for tens of ms; reading it directly yields torn frames (garbled
// OCR) and, on a resolution-change realloc, a use-after-free. We snapshot the
// pixel bytes into this buffer under `scratch_mutex` and hand the SCRATCH copy
// to the OCR wrapper. The buffer is reused across calls and only grown when a
// larger frame arrives (the proactive co-watcher OCRs frequently).
var scratch: ?[]u8 = null;
var scratch_mutex: sync.Mutex = .{};

/// Lazily initialize the OCR pipeline exactly once. Returns true if usable.
fn ensureOcrInit() bool {
    if (ocr_initialized.load(.acquire)) return true;
    if (ocr_init_failed.load(.acquire)) return false;

    // Tiny spinlock so two callers don't double-init concurrently. The init
    // call is one-shot and fast; contention is effectively nil.
    while (ocr_init_lock.cmpxchgWeak(false, true, .acquire, .monotonic) != null) {
        if (ocr_initialized.load(.acquire)) return true;
        if (ocr_init_failed.load(.acquire)) return false;
        std.atomic.spinLoopHint();
    }
    defer ocr_init_lock.store(false, .release);

    // Re-check inside the lock.
    if (ocr_initialized.load(.acquire)) return true;
    if (ocr_init_failed.load(.acquire)) return false;

    // Prefer PP-OCRv5 (same model set as comics.zig).
    const det_path = "models/ppocr_det_v5.onnx";
    const rec_path = "models/ppocr_rec_v5.onnx";
    const dict_path = "models/en_dict_v5.txt";

    const ret = ocr_c.ocr_init(det_path, rec_path, dict_path);
    if (ret != 0) {
        logs.pushLog("error", "frame_ocr", "OCR init failed — check models/ directory", true);
        ocr_init_failed.store(true, .release);
        return false;
    }
    ocr_initialized.store(true, .release);
    logs.pushLog("info", "frame_ocr", "OCR initialized (PP-OCRv5 ONNX)", false);
    return true;
}

/// OCR the active player's current video frame.
///
/// Returns the number of bytes written into `out_buf` (the recognized text,
/// truncated to fit). Returns 0 if there is no active player, the frame
/// buffer is not ready, OCR is unavailable, or anything goes wrong.
pub fn ocrCurrentFrame(out_buf: []u8) usize {
    if (out_buf.len == 0) return 0;

    // ── Guard active player access (see CLAUDE.md). ──
    if (state.app.active_player_idx >= state.app.players.items.len) return 0;
    const p = state.app.players.items[state.app.active_player_idx];

    // Pixel buffer must be allocated/ready.
    const pixels = p.pixels;
    if (pixels.len == 0) return 0;

    // Real frame dimensions: mpv renders into the full software surface.
    const w: c_int = player.video_w;
    const h: c_int = player.video_h;
    if (w <= 0 or h <= 0) return 0;

    // Sanity: the buffer must actually hold w*h pixels.
    const need: usize = @as(usize, @intCast(w)) * @as(usize, @intCast(h));
    if (pixels.len < need) return 0;

    if (!ensureOcrInit()) return 0;

    // ── Snapshot the live frame so OCR can't race mpv's render thread. ──
    // Each PMA pixel is 4 bytes; copy the exact w*h*4 byte window we need.
    const byte_len: usize = need * 4;
    const src_bytes: [*]const u8 = @ptrCast(pixels.ptr);

    scratch_mutex.lock();
    // Lazily allocate / grow the reusable scratch buffer.
    if (scratch == null or scratch.?.len < byte_len) {
        if (scratch) |old| alloc.allocator.free(old);
        scratch = null;
        scratch = alloc.allocator.alloc(u8, byte_len) catch {
            scratch_mutex.unlock();
            return 0;
        };
    }
    const buf = scratch.?;
    @memcpy(buf[0..byte_len], src_bytes[0..byte_len]);
    scratch_mutex.unlock();

    // Opaque video frame: PMA bytes == straight RGBA bytes. Pass the SNAPSHOT
    // (not the live p.pixels) so a concurrent render/realloc can't corrupt us.
    const rgba_ptr: [*]const u8 = buf.ptr;

    const result = ocr_c.ocr_recognize_rgba(rgba_ptr, w, h);
    if (result == null) return 0;
    defer ocr_c.ocr_free_text(result);

    const text: [*:0]const u8 = result.?;
    const text_slice = std.mem.span(text);
    const trimmed = std.mem.trim(u8, text_slice, " \t\r\n");
    const len = @min(trimmed.len, out_buf.len);
    if (len == 0) return 0;
    @memcpy(out_buf[0..len], trimmed[0..len]);
    return len;
}
