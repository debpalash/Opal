"""Transfers — gallery-dl download backend.
See tests/features/harness.py for the shared @test decorator, helpers, and
run_all()."""
from .harness import *  # noqa: F401,F403
import subprocess  # noqa: F401


@test("gallery-dl download backend", "Transfers")
def test_gallerydl_backend():
    # gallery-dl is an alternate download/extraction backend for image galleries
    # and art/booru sites yt-dlp doesn't cover. Backend plumbing only — NO new
    # tab. Invoked exactly like yt-dlp (a CLI child process).
    #
    # Verify: the pure module is registered + routed (so the tested
    # classification / argv / parse logic IS the shipped logic), the binary
    # resolver degrades gracefully when gallery-dl is absent, the URL dispatch
    # branch sits at the paste-a-URL download decision point, completions land
    # in download history, and a config toggle exists.
    pure = _src("src/services/gallerydl_pure.zig")
    svc = _src("src/services/gallerydl.zig")
    transfers = _src("src/services/transfers.zig")
    st = _src("src/core/state.zig")
    cfg = _src("src/core/config.zig")
    build = _src("build.zig")

    checks = {
        # ── Pure module: classification + argv + output parse ──
        "pure module present": bool(pure),
        "pure classification": "pub fn shouldUseGalleryDl" in pure,
        "pure argv builder": "pub fn buildArgv" in pure,
        "pure output parser": "pub fn parseOutputLine" in pure,
        "pure host extractor": "pub fn hostOf" in pure,
        # argv safety: `--` guard + discrete args (no shell string) tested.
        "argv guards leading dash": '"--"' in pure,
        # ── Service routes through the pure fns (tested == shipped) ──
        "service routes classification": "pure.buildArgv(" in svc,
        "service routes parser": "pure.parseOutputLine(" in svc,
        "service routes basename": "pure.baseName(" in svc,
        # ── Binary resolver (PATH lookup, inert when absent) ──
        "binary resolver": "pub fn binary()" in svc,
        "availability probe": "pub fn available()" in svc,
        "resolver checks candidates": "gallery-dl" in svc and "cwdAccess" in svc,
        "inert when missing": "if (!available()) return false;" in svc,
        # ── Async worker discipline ──
        "busy guard": "busy: std.atomic.Value(bool)" in svc,
        "copies inputs before spawn": "S.url_len = url.len;" in svc,
        "thread detached": "t.detach();" in svc,
        "never bare spawn": "_ = std.Thread.spawn(" not in svc,
        "heap output buffer": "alloc.alloc(u8," in svc,
        # ── Completion registered into download history ──
        "records into history": "history.addDownloadHistory(" in svc,
        # ── Dispatch branch at the download decision point ──
        "dispatch import": 'gallerydl = @import("gallerydl.zig")' in transfers,
        "dispatch pure import": 'gdl_pure = @import("gallerydl_pure.zig")' in transfers,
        "dispatch branch": (
            "gallerydl.enabled()" in transfers
            and "gdl_pure.shouldUseGalleryDl(" in transfers
            and "gallerydl.fetch(" in transfers
        ),
        "falls through to http": "httpdl.startUrl(clip)" in transfers,
        # ── Config toggle (default ON) ──
        "state field": "gallerydl_enabled: bool = true" in st,
        "config save": 'setKey("gallerydl_enabled"' in cfg,
        "config load": 'std.mem.eql(u8, key, "gallerydl_enabled")' in cfg,
        "enabled gate": "pub fn enabled()" in svc and "gallerydl_enabled" in svc,
        # ── Pure module registered in the `zig build test` step ──
        "test registered": 'b.path("src/services/gallerydl_pure.zig")' in build,
        # ── NO new tab (backend only) ──
        "no new drawer tab": "GalleryDl }" not in st and "renderRailTab(.GalleryDl" not in _src("src/ui/drawer.zig"),
    }
    missing = [k for k, ok in checks.items() if not ok]

    # Best-effort live probe: gallery-dl need not be installed for the suite to
    # pass (the feature is inert without it) — this only annotates the detail.
    probe = "not probed"
    for cand in ("/opt/homebrew/bin/gallery-dl", "/usr/local/bin/gallery-dl",
                 "/usr/bin/gallery-dl", "gallery-dl"):
        try:
            r = subprocess.run([cand, "--version"], capture_output=True,
                               text=True, timeout=10)
            if r.returncode == 0:
                probe = "gallery-dl " + r.stdout.strip().splitlines()[0]
                break
        except Exception:
            continue
    else:
        probe = "gallery-dl not installed (backend inert — pure tests cover logic)"

    if not missing:
        return "pass", f"gallery-dl backend wired: pure→service→dispatch→history+config. {probe}"
    return "fail", "gallery-dl wiring incomplete: " + ", ".join(missing)
