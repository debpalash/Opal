//! Voice setup — one-shot self-installer for the fast conversational stack:
//!   1. sherpa-onnx prebuilt CLIs (~26 MB, pinned GitHub release, macOS arm64)
//!   2. silero VAD model (~2 MB) — natural turn-taking
//!   3. NVIDIA Parakeet TDT 0.6B v3 int8 (~490 MB) — conversation +
//!      dictation, 25 languages, punctuated/cased output (measured RTF ~0.1
//!      on Apple Silicon CPU)
//! Everything lands under ~/.config/opal/ — no brew, no pip. Kicked
//! automatically after the first voice conversation (ai_voice), and safe to
//! re-run: every step skips work that's already on disk.

const std = @import("std");
const builtin = @import("builtin");
const io_global = @import("../core/io_global.zig");
const logs = @import("../core/logs.zig");
const state = @import("../core/state.zig");
const alloc = @import("../core/alloc.zig").allocator;

const SHERPA_URL = "https://github.com/k2-fsa/sherpa-onnx/releases/download/v1.13.3/sherpa-onnx-v1.13.3-osx-arm64-shared.tar.bz2";
const SHERPA_EXTRACT_DIR = "sherpa-onnx-v1.13.3-osx-arm64-shared";
const SILERO_URL = "https://github.com/k2-fsa/sherpa-onnx/releases/download/asr-models/silero_vad.onnx";
pub const NEMOTRON_DIR = "sherpa-onnx-nemotron-3.5-asr-streaming-0.6b-160ms-int8-2026-06-11";
const NEMOTRON_URL = "https://github.com/k2-fsa/sherpa-onnx/releases/download/asr-models/" ++ NEMOTRON_DIR ++ ".tar.bz2";

pub const SetupState = enum(u8) { idle, running, failed, done };
pub var setup_state: std.atomic.Value(u8) = std.atomic.Value(u8).init(0);

var msg_lock: @import("../core/sync.zig").Mutex = .{};
var msg_buf: [256]u8 = undefined;
var msg_len: usize = 0;

fn setMsg(m: []const u8) void {
    msg_lock.lock();
    const n = @min(m.len, msg_buf.len);
    @memcpy(msg_buf[0..n], m[0..n]);
    msg_len = n;
    msg_lock.unlock();
    logs.pushLog("info", "voice_setup", m, false);
    state.wakeUi();
}

/// Snapshot the live status line into `out` (for settings/UI display).
pub fn statusMsg(out: []u8) []const u8 {
    msg_lock.lock();
    defer msg_lock.unlock();
    const n = @min(msg_len, out.len);
    @memcpy(out[0..n], msg_buf[0..n]);
    return out[0..n];
}

// ── Path resolution (self-installed bundle first, then brew/local) ──

/// Resolve a sherpa CLI by name into `buf`. Probe order: the self-installed
/// bundle under ~/.config/opal/sherpa-onnx/bin, then Homebrew, then
/// /usr/local. Null when nowhere.
pub fn sherpaBin(comptime name: []const u8, buf: []u8) ?[]const u8 {
    if (io_global.getenv("HOME")) |home| {
        if (std.fmt.bufPrint(buf, "{s}/.config/opal/sherpa-onnx/bin/" ++ name, .{home})) |p| {
            if (io_global.cwdAccess(p, .{})) |_| return p else |_| {}
        } else |_| {}
    }
    if (io_global.cwdAccess("/opt/homebrew/bin/" ++ name, .{})) |_| {
        return "/opt/homebrew/bin/" ++ name;
    } else |_| {}
    if (io_global.cwdAccess("/usr/local/bin/" ++ name, .{})) |_| {
        return "/usr/local/bin/" ++ name;
    } else |_| {}
    return null;
}

/// ~/.config/opal/models/silero_vad.onnx, when present.
pub fn sileroPath(buf: []u8) ?[]const u8 {
    const home = io_global.getenv("HOME") orelse return null;
    const p = std.fmt.bufPrint(buf, "{s}/.config/opal/models/silero_vad.onnx", .{home}) catch return null;
    if (io_global.cwdAccess(p, .{})) |_| return p else |_| return null;
}

fn parakeetPresent(dir_name: []const u8) bool {
    const home = io_global.getenv("HOME") orelse return false;
    var buf: [512]u8 = undefined;
    const p = std.fmt.bufPrint(&buf, "{s}/.config/opal/models/{s}/encoder.int8.onnx", .{ home, dir_name }) catch return false;
    if (io_global.cwdAccess(p, .{})) |_| return true else |_| return false;
}

pub fn parakeetV3Present() bool {
    return parakeetPresent("sherpa-onnx-nemo-parakeet-tdt-0.6b-v3-int8");
}

pub fn parakeetV2Present() bool {
    return parakeetPresent("sherpa-onnx-nemo-parakeet-tdt-0.6b-v2-int8");
}

pub fn nemotronPresent() bool {
    return parakeetPresent(NEMOTRON_DIR); // same encoder.int8.onnx layout
}

/// TRUE streaming conversation: the online mic CLI + Nemotron 3.5 streaming.
pub fn streamingReady() bool {
    var bin_buf: [512]u8 = undefined;
    if (sherpaBin("sherpa-onnx-microphone", &bin_buf) == null) return false;
    return nemotronPresent();
}

/// VAD + offline-ASR fallback: vad mic CLI + silero + a Parakeet model.
pub fn vadConvoReady() bool {
    var bin_buf: [512]u8 = undefined;
    if (sherpaBin("sherpa-onnx-vad-microphone-offline-asr", &bin_buf) == null) return false;
    var sil_buf: [512]u8 = undefined;
    if (sileroPath(&sil_buf) == null) return false;
    return parakeetV3Present() or parakeetV2Present();
}

/// Any self-installed conversational pipeline available?
pub fn convoReady() bool {
    return streamingReady() or vadConvoReady();
}

// ── Installer ──

fn runStep(argv: []const []const u8) bool {
    var child = io_global.Child.init(argv, alloc);
    child.stdin_behavior = .Ignore;
    child.stdout_behavior = .Ignore;
    child.stderr_behavior = .Ignore;
    _ = child.spawn() catch return false;
    const term = child.wait() catch return false;
    return switch (term) {
        .exited => |code| code == 0,
        else => false,
    };
}

pub fn installAsync() void {
    if (builtin.os.tag == .macos and builtin.cpu.arch != .aarch64) {
        setMsg("Self-install is Apple-Silicon-only for now — brew install sherpa-onnx instead");
        return;
    }
    if (setup_state.swap(@intFromEnum(SetupState.running), .acq_rel) == @intFromEnum(SetupState.running)) return;
    setMsg("Preparing voice setup…");
    if (std.Thread.spawn(.{}, installWorker, .{})) |t| t.detach() else |_| {
        setup_state.store(@intFromEnum(SetupState.failed), .release);
        setMsg("Could not start the voice installer");
    }
}

fn installWorker() void {
    const fail = struct {
        fn f(m: []const u8) void {
            setup_state.store(@intFromEnum(SetupState.failed), .release);
            setMsg(m);
        }
    }.f;

    const home = io_global.getenv("HOME") orelse return fail("HOME not set");
    var dir_buf: [512]u8 = undefined;
    const opal_dir = std.fmt.bufPrint(&dir_buf, "{s}/.config/opal", .{home}) catch return fail("path too long");
    var models_buf: [512]u8 = undefined;
    const models_dir = std.fmt.bufPrint(&models_buf, "{s}/models", .{opal_dir}) catch return fail("path too long");
    io_global.makeDirAbsolute(models_dir) catch {};

    // 1) sherpa-onnx CLI bundle (skip when its offline binary already exists)
    var probe_buf: [512]u8 = undefined;
    const have_bundle = blk: {
        const p = std.fmt.bufPrint(&probe_buf, "{s}/sherpa-onnx/bin/sherpa-onnx-offline", .{opal_dir}) catch break :blk false;
        if (io_global.cwdAccess(p, .{})) |_| break :blk true else |_| break :blk false;
    };
    if (!have_bundle) {
        setMsg("Downloading voice engine (26 MB)…");
        var tar_buf: [512]u8 = undefined;
        const tar_path = std.fmt.bufPrint(&tar_buf, "{s}/sherpa-onnx.tar.bz2", .{opal_dir}) catch return fail("path too long");
        if (!runStep(&.{ "curl", "-L", "--fail", "--silent", "--show-error", "-o", tar_path, SHERPA_URL }))
            return fail("Voice engine download failed — check network and retry");
        setMsg("Unpacking voice engine…");
        if (!runStep(&.{ "tar", "-xjf", tar_path, "-C", opal_dir }))
            return fail("Voice engine unpack failed");
        io_global.deleteFileAbsolute(tar_path) catch {};
        var src_buf: [512]u8 = undefined;
        const src = std.fmt.bufPrint(&src_buf, "{s}/" ++ SHERPA_EXTRACT_DIR, .{opal_dir}) catch return fail("path too long");
        var dst_buf: [512]u8 = undefined;
        const dst = std.fmt.bufPrint(&dst_buf, "{s}/sherpa-onnx", .{opal_dir}) catch return fail("path too long");
        if (!runStep(&.{ "mv", src, dst }))
            return fail("Voice engine install failed (mv)");
    }

    // NOTE: Nemotron 3.5 streaming (NEMOTRON_URL) is deliberately NOT in the
    // default install: its int8 export measured RTF 1.3 on an M-series Air
    // CPU — it falls behind live audio. The spawn path exists for machines
    // that can afford it (drop the bundle into models/ manually).

    // 2) silero VAD (2 MB) — turn-taking for the conversational loop
    var sil_buf: [512]u8 = undefined;
    if (sileroPath(&sil_buf) == null) {
        setMsg("Downloading VAD model (2 MB)…");
        var out_buf: [512]u8 = undefined;
        const out = std.fmt.bufPrint(&out_buf, "{s}/silero_vad.onnx", .{models_dir}) catch return fail("path too long");
        if (!runStep(&.{ "curl", "-L", "--fail", "--silent", "--show-error", "-o", out, SILERO_URL }))
            return fail("VAD model download failed — check network and retry");
    }

    // 3) Parakeet TDT 0.6B v3 (~490 MB) — conversation + dictation, 25 langs
    if (!parakeetV3Present()) {
        setMsg("Downloading Parakeet TDT v3 (~490 MB — a few minutes)…");
        if (!@import("../core/deps.zig").fetchParakeetBlocking(true))
            return fail("Parakeet v3 download failed — check network/disk and retry");
    }

    if (!convoReady())
        return fail("Voice setup incomplete — see Logs");

    // Promote the backend so the next conversation uses the new stack
    // (user's explicit Settings choice still overrides afterwards).
    const vb = @import("voice_backend.zig");
    vb.active_kind = .parakeet_tdt_v3;
    state.markConfigDirty();

    setup_state.store(@intFromEnum(SetupState.done), .release);
    setMsg("Voice ready — Parakeet v3 conversational mode installed");
    state.showToast("Voice upgraded: Parakeet v3 ready — toggle conversation to use it");
}
