"""Perception (ROADMAP 7.2) — perceptual duplicate detection and automatic chapters.

The behavioural checks build tests/tools/*_probe.zig against the shipped pure
modules and run them on ffmpeg-generated clips, so the argv, hashing, distance
and chapter logic under test is the production code. The wiring checks pin the
paths that feed those modules (schema, worker, API, player)."""
import os
import shutil
import subprocess
import tempfile

from .harness import *  # noqa: F401,F403


def _tools():
    zig, ffmpeg, ffprobe = shutil.which("zig"), shutil.which("ffmpeg"), shutil.which("ffprobe")
    return (zig, ffmpeg, ffprobe) if zig and ffmpeg and ffprobe else None


def _ffmpeg(*args):
    return subprocess.run(["ffmpeg", "-v", "error", "-y", *args], capture_output=True, text=True, timeout=180)


def _probe(zig, tool, dep, module, *args):
    r = subprocess.run([zig, "run", "--dep", dep, "-Mroot=tests/tools/" + tool, "-M%s=%s" % (dep, module), "--", *args],
                       cwd=PROJECT_DIR, capture_output=True, text=True, timeout=600)
    return r.stdout if r.returncode == 0 else None, r.stderr[-400:]


@test("Perceptual duplicates: same clip at two resolutions matches, a different clip does not", "Perception")
def test_phash_fixture_clips():
    tools = _tools()
    if not tools:
        return "skip", "zig/ffmpeg/ffprobe not available"
    zig, ffmpeg, ffprobe = tools
    with tempfile.TemporaryDirectory() as td:
        base, small, other = (os.path.join(td, n) for n in ("base.mp4", "small.mp4", "other.mp4"))
        steps = [
            ("-f", "lavfi", "-i", "testsrc2=size=640x360:rate=25:duration=12", "-c:v", "libx264", "-pix_fmt", "yuv420p", base),
            # Re-encode at a quarter of the pixels and a much lower quality.
            ("-i", base, "-vf", "scale=320:180", "-c:v", "libx264", "-crf", "34", small),
            # Different content, same length, so the hash (not the duration gate) decides.
            ("-f", "lavfi", "-i", "mandelbrot=size=640x360:rate=25", "-t", "12", "-c:v", "libx264", "-pix_fmt", "yuv420p", other),
        ]
        for step in steps:
            r = _ffmpeg(*step)
            if r.returncode:
                return "skip", "ffmpeg cannot generate fixtures: " + r.stderr[-200:]
        out, err = _probe(zig, "phash_probe.zig", "phash", "src/services/phash_pure.zig", ffmpeg, ffprobe, base, small, other)
        if out is None:
            return "fail", "phash_probe failed: " + err
        rows = {line.split()[0]: dict(kv.split("=") for kv in line.split()[1:]) for line in out.strip().splitlines()}
        s, o = rows.get(small), rows.get(other)
        if not s or not o:
            return "fail", "probe output incomplete: %r" % out
        if s["duplicate"] != "1" or int(s["valid"]) < 3:
            return "fail", "re-encoded 320x180 copy did not match the 640x360 original: %r" % s
        if o["duplicate"] != "0":
            return "fail", "unrelated clip matched: %r" % o
    return "pass", "2-resolution copy matches (mean %s bits), different clip mean %s bits" % (s["mean"], o["mean"])


@test("Automatic chapters land on the scene cuts of a generated multi-scene clip", "Perception")
def test_auto_chapters_fixture_clip():
    tools = _tools()
    if not tools:
        return "skip", "zig/ffmpeg/ffprobe not available"
    zig, ffmpeg, ffprobe = tools
    with tempfile.TemporaryDirectory() as td:
        clip = os.path.join(td, "scenes.mp4")
        r = _ffmpeg("-f", "lavfi", "-i", "testsrc2=size=640x360:rate=25:duration=20",
                    "-f", "lavfi", "-i", "smptehdbars=size=640x360:rate=25:duration=20",
                    "-f", "lavfi", "-i", "mandelbrot=size=640x360:rate=25",
                    "-filter_complex", "[2:v]trim=duration=20,setpts=PTS-STARTPTS[m];[0:v][1:v][m]concat=n=3:v=1:a=0,format=yuv420p[v]",
                    "-map", "[v]", "-c:v", "libx264", "-preset", "veryfast", clip)
        if r.returncode:
            return "skip", "ffmpeg cannot generate the clip: " + r.stderr[-200:]
        out, err = _probe(zig, "chapters_probe.zig", "chapters", "src/services/auto_chapters_pure.zig", ffmpeg, ffprobe, clip)
        if out is None:
            return "fail", "chapters_probe failed: " + err
        starts = [float(line.split()[0]) for line in out.strip().splitlines()[1:]]
        if len(starts) != 3 or starts[0] != 0 or abs(starts[1] - 20) > 1 or abs(starts[2] - 40) > 1:
            return "fail", "expected chapters at 0/20/40 s, got %r" % starts
        # Merged with a detected intro, the intro is a named chapter.
        out, err = _probe(zig, "chapters_probe.zig", "chapters", "src/services/auto_chapters_pure.zig", ffmpeg, ffprobe, clip, "0", "9")
        if out is None or "0.000 Intro" not in out or "9.000 Chapter 1" not in out:
            return "fail", "intro marker not merged: %r %s" % (out, err)
    return "pass", "chapters at %s; intro merges as a named chapter" % ", ".join("%.1f" % s for s in starts)


@test("Perception wiring: schema, on-demand phash worker, API, library UI, mpv chapter feed", "Perception")
def test_perception_wiring():
    db, build = _src("src/core/db.zig"), _src("build.zig")
    worker, lib, api = _src("src/services/phash.zig"), _src("src/services/local_library.zig"), _src("src/services/remote_local_library_api.zig")
    chapters, markers = _src("src/services/auto_chapters.zig"), _src("src/services/markers.zig")
    tick, native, web = _src("src/application/playback_update.zig"), _src("src/ui/local_library_ui.zig"), _src("web/js/integrations.js")
    checks = {
        "media_phash schema": "CREATE TABLE IF NOT EXISTS media_phash" in db and "idx_media_phash_group" in db,
        "media_auto_chapters schema": "CREATE TABLE IF NOT EXISTS media_auto_chapters" in db,
        "pure modules in zig test step": '"src/services/phash_pure.zig"' in build and '"src/services/auto_chapters_pure.zig"' in build,
        "worker routes through pure": all(f in worker for f in ("pure.frameArgv(", "pure.setSample(", "pure.group(", "pure.usable(")),
        "worker is low priority and bounded": '"/usr/bin/nice"' in worker and "bounded_process.run(" in worker,
        "duplicates request starts signing": 'if (duplicates_only) @import("phash.zig").ensureAsync()' in lib,
        "duplicates include visual groups": "media_phash WHERE group_id>0" in lib and "visual_count" in lib,
        "API route": '"/local-library/visual-duplicates"' in api and '"visual-scan"' in api and '\\"visual_copies\\"' in api,
        "API never returns paths": '\\"path\\"' not in api,
        "native + web surfaces": "layout.duplicateLabel(" in native and "visual_copies" in web,
        "chapters route through pure": all(f in chapters for f in ("pure.sceneArgv(", "pure.parseScenes(", "pure.build(", "pure.encode(", "pure.decode(")),
        "chapters only fill an empty list": '"chapter-list/count"' in chapters and "if (count > 0) return;" in chapters,
        "chapters feed mpv + skip logic": '"chapter-list", c.mpv.MPV_FORMAT_NODE' in chapters
            and "mm.chapterSegments(" in chapters and "skip_segments.publish(.chapters" in chapters,
        "markers hand intro/credits to chapters": '@import("auto_chapters.zig").run(' in markers and "want_chapters" in markers,
        "owner-thread apply": 'auto_chapters.zig").tick()' in tick,
    }
    bad = [k for k, ok in checks.items() if not ok]
    return ("fail", "missing: " + ", ".join(bad)) if bad else ("pass", f"{len(checks)} perception wiring checks")
