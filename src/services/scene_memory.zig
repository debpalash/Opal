//! Total Recall — scene-level lifetime memory (Task T1).
//!
//! As the Co-Watcher runs, it hands us the now-playing title + position and a
//! joined blob of subtitle / recent-dialogue / OCR text. We dedup against a
//! small ring of recent (title-hash, text-hash) pairs so we only embed on a
//! meaningful delta (not on every co-watch tick), drop OCR/ad junk via the same
//! poison filter ai_memory uses, embed the text, and persist it as a timestamped
//! SCENE memory in the vector store (db.insertSceneMemory).
//!
//! Runs on the CALLER thread (the co_watch detached worker). The fixed buffers
//! here are small and fine on that stack; nothing >64KB lives on the stack.
//!
//! Robustness contract: NEVER crash; degrade silently. Every failure path is a
//! quiet early return. If embedding is unavailable we still persist an
//! FTS/keyword-findable row (embed == null), so recall works without the
//! embedding server.

const std = @import("std");
const ai_memory = @import("ai_memory.zig");

// ── Dedup ring ──────────────────────────────────────────────────────────────
// A tiny ring of the last N (title-hash, text-hash) pairs. If the incoming
// (title, text) hashes match any recent entry we skip — same held subtitle, or
// a co-watch re-trigger on an unchanged frame, shouldn't re-embed.

const RING_N = 16;
const MIN_TEXT_LEN = 12;

const DedupEntry = struct {
    title_hash: u64 = 0,
    text_hash: u64 = 0,
    used: bool = false,
};

const Ring = struct {
    var entries: [RING_N]DedupEntry = [_]DedupEntry{.{}} ** RING_N;
    var head: usize = 0;
    var mutex: @import("../core/sync.zig").Mutex = .{};

    /// Returns true if (title_hash, text_hash) is already in the ring; otherwise
    /// records it and returns false. Serialized — the co_watch worker is the
    /// only caller today, but a second voice path could race it.
    fn seenOrRecord(title_hash: u64, text_hash: u64) bool {
        mutex.lock();
        defer mutex.unlock();
        for (entries) |e| {
            if (e.used and e.title_hash == title_hash and e.text_hash == text_hash) {
                return true;
            }
        }
        entries[head] = .{ .title_hash = title_hash, .text_hash = text_hash, .used = true };
        head = (head + 1) % RING_N;
        return false;
    }
};

/// Persist one scene observation. Cheap-gated, then embed + insert.
///
/// title    — now-playing media title (may be empty; we still store, untitled).
/// pos_secs — playback position of this scene (the seek target on recall).
/// dur_secs — total duration (currently informational; reserved).
/// text     — joined subtitle + recent-dialogue + OCR blob.
pub fn ingestScene(title: []const u8, pos_secs: f64, dur_secs: f64, text: []const u8) void {
    if (@import("../core/state.zig").app.incognito_mode) return; // incognito: no lifetime scene memory
    _ = dur_secs; // reserved; position is the recall anchor.

    // (1a) Trim and length-gate. Tiny or empty blobs aren't worth a row.
    const trimmed = std.mem.trim(u8, text, " \t\r\n");
    if (trimmed.len < MIN_TEXT_LEN) return;

    // (2) Junk/poison filter — reuse ai_memory's tool-plumbing / garbage reject.
    if (ai_memory.isJunkTurn(trimmed)) return;

    // (1b) Dedup against the recent ring so we only embed on meaningful deltas.
    const title_hash = std.hash.Wyhash.hash(0, title);
    const text_hash = std.hash.Wyhash.hash(0, trimmed);
    if (Ring.seenOrRecord(title_hash, text_hash)) return;

    // (3) Embed. The buffer is a fixed [EMBED_DIM]f32 — fine on this stack
    // (768 * 4 = 3 KiB, well under the 64 KiB thread-stack limit).
    var buf: [ai_memory.EMBED_DIM]f32 = undefined;
    const ok = ai_memory.getEmbedding(trimmed, &buf);

    // Persist. If embedding failed we pass null so db inserts an FTS/keyword-
    // findable row only (recall fallback is mandatory).
    @import("../core/db.zig").insertSceneMemory(
        title,
        trimmed,
        pos_secs,
        if (ok) buf[0..] else null,
    );
}
