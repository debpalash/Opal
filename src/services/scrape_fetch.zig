const std = @import("std");
const alloc = @import("../core/alloc.zig").allocator;
const logs = @import("../core/logs.zig");
const state = @import("../core/state.zig");
const io_g = @import("../core/io_global.zig");
const browser = @import("browser.zig");
const pure = @import("scrape_fetch_pure.zig");

// ══════════════════════════════════════════════════════════
// Anti-block scrape fetch — the "never blocked" fetch layer
//
// scrapeFetch() is a drop-in replacement for the plain-HTTP / curl fetch every
// scraper does today, with one difference: when the fast plain fetch comes
// back as a Cloudflare / DDoS-Guard / JS-challenge / captcha interstitial (see
// scrape_fetch_pure.needsBrowser), it transparently RE-FETCHES the same URL
// through Opal's already-integrated anti-detect browser (camoufox /
// CloakBrowser via the Playwright bridge), which passes those challenges, and
// returns the unblocked HTML/JSON instead.
//
// SYNCHRONOUS — call from a scraper WORKER thread (exactly like curl today),
// never the UI thread. The browser fallback can block up to ~45s.
//
// Block detection is routed entirely through scrape_fetch_pure so the tested
// logic IS the shipped logic (no drift). See that module for the marker set
// and the false-positive guards (a footer that merely says "Cloudflare" is not
// a block).
// ══════════════════════════════════════════════════════════

const BROWSER_UA = "Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 " ++
    "(KHTML, like Gecko) Chrome/124.0.0.0 Safari/537.36";

// One-time "anti-block fetch ready" note so the capability is discoverable in
// the Logs tab the first time any scraper reaches for it.
var announced = std.atomic.Value(bool).init(false);

fn announceReady() void {
    if (announced.swap(true, .acq_rel)) return;
    logs.pushLog("info", "scrape", "Anti-block fetch ready (browser fallback on Cloudflare/captcha)", true);
}

/// Is the browser-backed fallback usable right now? Config toggle ON and an
/// anti-detect engine installed.
fn browserFallbackAvailable() bool {
    if (!state.app.scrape_use_browser) return false;
    return browser.engineReady(browser.active_engine);
}

/// Plain HTTP GET via curl, capturing the final status code, response headers,
/// and body. Body → out_buf; headers → hdr_buf. Returns the body slice (into
/// out_buf) or null. Headers/status feed the pure block detector.
///
/// curl writes headers to stderr (`-D /dev/stderr`) and the body to stdout, so
/// the two streams come back on separate pipes with no interleaving to untangle.
fn plainFetch(url: []const u8, out_buf: []u8, hdr_buf: []u8, hdr_len: *usize, status: *u16) ?[]const u8 {
    hdr_len.* = 0;
    status.* = 0;

    // Route through the reliable-fetch backend: curl-impersonate (browser
    // JA3/JA4) when installed, else plain curl, PLUS the DPI-bypass proxy when
    // enabled — this scrape path previously had neither (a real gap). We build
    // the argv here (not reliable_fetch.fetch) because we also need curl's
    // response headers on stderr (`-D /dev/stderr`) for the block detector.
    const be = @import("reliable_fetch.zig").backend();
    var argv: [24][]const u8 = undefined;
    var an: usize = 0;
    argv[an] = be.bin;
    an += 1;
    if (be.token.len > 0) {
        argv[an] = "--impersonate";
        an += 1;
        argv[an] = be.token;
        an += 1;
    }
    for ([_][]const u8{ "-s", "-L", "--compressed", "-A", BROWSER_UA, "--max-time", "20", "-D", "/dev/stderr", "-o", "-" }) |a| {
        argv[an] = a;
        an += 1;
    }
    if (@import("dpi_bypass.zig").proxyArgs()) |pa| {
        for (pa) |a| {
            if (an >= argv.len - 1) break;
            argv[an] = a;
            an += 1;
        }
    }
    argv[an] = url;
    an += 1;

    var child = io_g.Child.init(argv[0..an], alloc);
    child.stdin_behavior = .Ignore;
    child.stdout_behavior = .Pipe;
    child.stderr_behavior = .Pipe;
    _ = child.spawn() catch return null;

    // Read the body (stdout) to completion first. curl emits the (small)
    // header block to stderr before the body, so it is already buffered in the
    // stderr pipe — reading stdout fully cannot deadlock against it.
    var body_len: usize = 0;
    if (child.stdout) |*stdout| {
        while (body_len < out_buf.len) {
            const r = io_g.read(stdout, out_buf[body_len..]) catch break;
            if (r == 0) break;
            body_len += r;
        }
        // Drain any excess so curl never blocks on a full stdout pipe.
        var junk: [4096]u8 = undefined;
        while (true) {
            const r = io_g.read(stdout, &junk) catch break;
            if (r == 0) break;
        }
    }

    if (child.stderr) |*stderr| {
        var hl: usize = 0;
        while (hl < hdr_buf.len) {
            const r = io_g.read(stderr, hdr_buf[hl..]) catch break;
            if (r == 0) break;
            hl += r;
        }
        var junk: [4096]u8 = undefined;
        while (true) {
            const r = io_g.read(stderr, &junk) catch break;
            if (r == 0) break;
        }
        hdr_len.* = hl;
    }

    _ = child.wait() catch {};

    status.* = pure.parseStatus(hdr_buf[0..hdr_len.*]);
    return out_buf[0..body_len];
}

/// Fetch `url` into `out_buf`, transparently defeating Cloudflare/DDoS-Guard/
/// captcha blocks via the anti-detect browser when the plain fetch is blocked.
/// Returns the (possibly browser-unblocked) body, or null if nothing could be
/// fetched. SYNCHRONOUS — worker-thread only.
pub fn scrapeFetch(url: []const u8, out_buf: []u8) ?[]const u8 {
    announceReady();
    if (url.len == 0 or out_buf.len == 0) return null;

    var hdr_buf: [16 * 1024]u8 = undefined;
    var hdr_len: usize = 0;
    var status: u16 = 0;
    const body = plainFetch(url, out_buf, &hdr_buf, &hdr_len, &status);

    const body_head = if (body) |b| b[0..@min(b.len, 16 * 1024)] else "";
    const headers = hdr_buf[0..hdr_len];

    // Not blocked → the fast path result stands.
    if (!pure.needsBrowser(status, headers, body_head)) {
        return body;
    }

    // Blocked. Fall back to the anti-detect browser if it is available.
    if (!browserFallbackAvailable()) {
        logs.pushLog("warn", "scrape", "Blocked page and browser fallback is off/unavailable — returning plain body", false);
        return body; // best-effort (may be the challenge page)
    }

    logs.pushLog("info", "scrape", "Blocked — retrying through the anti-detect browser", true);
    if (browser.fetchHtmlBlocking(url, out_buf)) |html| {
        return html;
    }

    // Browser path failed/timed out — best-effort plain body. `out_buf` may
    // have been overwritten by fetchHtmlBlocking on partial failure, so re-run
    // the plain fetch to hand back a clean (if blocked) body rather than junk.
    return plainFetch(url, out_buf, &hdr_buf, &hdr_len, &status);
}
