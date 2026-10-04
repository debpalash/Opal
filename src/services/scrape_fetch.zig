const std = @import("std");
const logs = @import("../core/logs.zig");
const state = @import("../core/state.zig");
const browser = @import("browser.zig");
const pure = @import("scrape_fetch_pure.zig");
const reliable_fetch = @import("reliable_fetch.zig");
const browser_fetch = @import("browser_fetch.zig");

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
fn plainFetch(
    url: []const u8,
    post_body: ?[]const u8,
    out_buf: []u8,
    hdr_buf: []u8,
    hdr_len: *usize,
    status: *u16,
    succeeded: *bool,
    cancel_epoch: ?@import("../core/bounded_process.zig").CancelEpoch,
) ?[]const u8 {
    hdr_len.* = 0;
    status.* = 0;
    succeeded.* = false;
    const form_headers = [_]reliable_fetch.Header{.{ .name = "Content-Type", .value = "application/x-www-form-urlencoded" }};
    const result = reliable_fetch.request(url, out_buf, hdr_buf, .{
        .user_agent = BROWSER_UA,
        .headers = if (post_body != null) &form_headers else &.{},
        .post_body = post_body,
        .timeout_secs = 20,
        .cancel_epoch = cancel_epoch,
    });
    hdr_len.* = result.headers.len;
    status.* = result.status;
    succeeded.* = result.ok();
    if (result.body.len == 0 and result.status == 0) return null;
    return result.body;
}

/// Fetch `url` into `out_buf`, transparently defeating Cloudflare/DDoS-Guard/
/// captcha blocks via the anti-detect browser when the plain fetch is blocked.
/// Returns the (possibly browser-unblocked) body, or null if nothing could be
/// fetched. SYNCHRONOUS — worker-thread only.
pub fn scrapeFetch(url: []const u8, out_buf: []u8) ?[]const u8 {
    return scrapeFetchBody(url, null, out_buf, null);
}

/// POST variant. `post_body` is sent as `application/x-www-form-urlencoded` on
/// both the plain path and the browser fallback, so a site that only reveals
/// what a scraper needs in response to a form POST (EZTV's `layout=def_wlinks`,
/// which is what gates its magnet links) is reachable through the unblock path
/// rather than only over GET.
pub fn scrapeFetchPost(url: []const u8, post_body: []const u8, out_buf: []u8) ?[]const u8 {
    return scrapeFetchBody(url, post_body, out_buf, null);
}

/// Compatibility-preserving Browse worker cancellation. The supervised plain
/// request is cancelled physically. An already-issued browser scrape must drain
/// its shared response before another scrape can safely acquire the single page.
pub fn scrapeFetchWithCancellation(url: []const u8, out_buf: []u8, epoch: ?@import("../core/bounded_process.zig").CancelEpoch) ?[]const u8 {
    return scrapeFetchBody(url, null, out_buf, epoch);
}
fn cancelled(epoch: ?@import("../core/bounded_process.zig").CancelEpoch) bool {
    const token = epoch orelse return false;
    return switch (token) {
        .epoch32 => |e| e.value.load(.acquire) != e.expected,
        .epoch64 => |e| e.value.load(.acquire) != e.expected,
    };
}
fn scrapeFetchBody(url: []const u8, post_body: ?[]const u8, out_buf: []u8, cancel_epoch: ?@import("../core/bounded_process.zig").CancelEpoch) ?[]const u8 {
    announceReady();
    if (url.len == 0 or out_buf.len == 0 or cancelled(cancel_epoch)) return null;

    var hdr_buf: [16 * 1024]u8 = undefined;
    var hdr_len: usize = 0;
    var status: u16 = 0;
    var plain_succeeded = false;
    const body = plainFetch(url, post_body, out_buf, &hdr_buf, &hdr_len, &status, &plain_succeeded, cancel_epoch);
    if (cancelled(cancel_epoch)) return null;

    const body_head = if (body) |b| b[0..@min(b.len, 16 * 1024)] else "";
    const headers = hdr_buf[0..hdr_len];

    // Not blocked → the fast path result stands.
    if (!pure.needsBrowser(status, headers, body_head)) {
        // The typed fetch may intentionally expose an error body for challenge
        // classification, but a 4xx/5xx document is never scraper content.
        return if (plain_succeeded) body else null;
    }

    // Blocked. First ask the user's own paired browser: it has their cookies
    // and a real fingerprint, and needs no Python or engine download. It never
    // prompts from here (an origin the user has not allowed answers "not
    // allowed" at once; a private-network target is refused the same way unless the
    // user named it). A page that is
    // still a challenge, or an error status, falls through to the bridge.
    if (cancelled(cancel_epoch)) return null;
    if (browser_fetch.fetchText(url, post_body, out_buf, cancel_epoch)) |t| {
        if (cancelled(cancel_epoch)) return null;
        const head = t.body[0..@min(t.body.len, 16 * 1024)];
        if (t.status < 400 and t.body.len > 0 and !pure.needsBrowser(t.status, "", head)) {
            logs.pushLog("info", "scrape", "Blocked: fetched through the paired browser", true);
            return t.body;
        }
    }

    // Then the anti-detect browser, if it is available.
    if (cancelled(cancel_epoch)) return null;
    if (!browserFallbackAvailable()) {
        logs.pushLog("warn", "scrape", "Blocked page and browser fallback is off/unavailable", false);
        return null;
    }

    logs.pushLog("info", "scrape", "Blocked — retrying through the anti-detect browser", true);
    const unblocked = browser.fetchHtmlWithCancellation(url, post_body, out_buf, cancel_epoch);
    if (cancelled(cancel_epoch)) return null;
    if (unblocked) |html| return html;

    // Browser path failed/timed out. Never hand the original challenge/error
    // document to a parser as though it were the requested content.
    return null;
}
