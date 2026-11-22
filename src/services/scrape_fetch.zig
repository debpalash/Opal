const std = @import("std");
const logs = @import("../core/logs.zig");
const state = @import("../core/state.zig");
const browser = @import("browser.zig");
const pure = @import("scrape_fetch_pure.zig");
const reliable_fetch = @import("reliable_fetch.zig");
const browser_fetch = @import("browser_fetch.zig");
const policy = @import("extraction_policy_pure.zig");

// ══════════════════════════════════════════════════════════
// Anti-block scrape fetch
//
// scrapeFetch() is a drop-in replacement for the plain-HTTP / curl fetch every
// scraper does today. When the fast plain fetch comes back as a Cloudflare /
// DDoS-Guard / JS-challenge / captcha interstitial (see
// scrape_fetch_pure.needsBrowser) AND the user has opted in
// (`extraction_browser_opt_in`, default off), it re-fetches the same URL
// through the paired browser, then the anti-detect engine (camoufox /
// CloakBrowser via the Playwright bridge). The order and the typed outcome
// come from extraction_policy_pure; without the opt-in no browser is used.
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
    logs.pushLog("info", "scrape", if (state.app.extraction_browser_opt_in)
        "Anti-block fetch ready (browser fallback on Cloudflare/captcha is on)"
    else
        "Anti-block fetch ready (browser fallback is off until you opt in)", false);
}

/// What the browser tiers look like right now. The opt-in is read first: with
/// it off, nothing else about the browsers is consulted.
fn availability() policy.Availability {
    if (!state.app.extraction_browser_opt_in) return .{};
    return .{
        .opted_in = true,
        .paired_connected = browser_fetch.connected(),
        .engine_ready = browser.engineReady(browser.active_engine),
    };
}

/// A typed fetch result: the body (into the caller's buffer) when the outcome
/// is `.ok`, the tier that produced it, and why it failed otherwise.
pub const Fetch = struct {
    outcome: policy.Outcome,
    tier: policy.Tier = .plain,
    body: ?[]const u8 = null,
};

/// `/api/scrape` error body naming the typed outcome.
pub fn errorJson(buf: []u8, outcome: policy.Outcome) []const u8 {
    return std.fmt.bufPrint(buf, "{{\"error\":\"fetch failed\",\"outcome\":\"{s}\"}}", .{outcome.label()}) catch "{\"error\":\"fetch failed\"}";
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
    connect_to: ?[]const u8,
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
        // Hops are checked here. curl must not follow a redirect on its own.
        .follow_redirects = false,
        .connect_to = connect_to,
    });
    hdr_len.* = result.headers.len;
    status.* = result.status;
    succeeded.* = result.ok();
    if (result.body.len == 0 and result.status == 0) return null;
    return result.body;
}

/// Fetch `url` into `out_buf`. A challenge page is retried through a browser
/// only with the user's opt-in (see extraction_policy_pure). Returns the body,
/// or null if nothing could be fetched. SYNCHRONOUS — worker-thread only.
pub fn scrapeFetch(url: []const u8, out_buf: []u8) ?[]const u8 {
    return scrapeFetchBody(url, null, out_buf, null).body;
}

/// POST variant. `post_body` is sent as `application/x-www-form-urlencoded` on
/// both the plain path and the browser fallback, so a site that only reveals
/// what a scraper needs in response to a form POST (EZTV's `layout=def_wlinks`,
/// which is what gates its magnet links) is reachable through the unblock path
/// rather than only over GET.
pub fn scrapeFetchPost(url: []const u8, post_body: []const u8, out_buf: []u8) ?[]const u8 {
    return scrapeFetchBody(url, post_body, out_buf, null).body;
}

/// Typed variant: the outcome says why a fetch came back empty (refused
/// target, HTTP error, blocked without the browser opt-in, ...).
pub fn scrapeFetchTyped(url: []const u8, post_body: ?[]const u8, out_buf: []u8) Fetch {
    return scrapeFetchBody(url, post_body, out_buf, null);
}

/// Compatibility-preserving Browse worker cancellation. The supervised plain
/// request is cancelled physically. An already-issued browser scrape must drain
/// its shared response before another scrape can safely acquire the single page.
pub fn scrapeFetchWithCancellation(url: []const u8, out_buf: []u8, epoch: ?@import("../core/bounded_process.zig").CancelEpoch) ?[]const u8 {
    return scrapeFetchBody(url, null, out_buf, epoch).body;
}
fn cancelled(epoch: ?@import("../core/bounded_process.zig").CancelEpoch) bool {
    const token = epoch orelse return false;
    return switch (token) {
        .epoch32 => |e| e.value.load(.acquire) != e.expected,
        .epoch64 => |e| e.value.load(.acquire) != e.expected,
    };
}

const cancelled_fetch: Fetch = .{ .outcome = .cancelled };
const refused_fetch: Fetch = .{ .outcome = .refused_target };

fn scrapeFetchBody(requested_url: []const u8, requested_post: ?[]const u8, out_buf: []u8, cancel_epoch: ?@import("../core/bounded_process.zig").CancelEpoch) Fetch {
    announceReady();
    if (cancelled(cancel_epoch)) return cancelled_fetch;
    if (requested_url.len == 0 or out_buf.len == 0 or requested_url.len > 2048) return refused_fetch;

    const targets = @import("fetch_target.zig");
    const target_policy = @import("fetch_target_pure.zig");
    const http_pure = @import("../core/http_std_pure.zig");

    var url_buf: [2048]u8 = undefined;
    @memcpy(url_buf[0..requested_url.len], requested_url);
    var current_len: usize = requested_url.len;
    var post = requested_post;

    var hdr_buf: [16 * 1024]u8 = undefined;
    var hdr_len: usize = 0;
    var status: u16 = 0;
    var plain_succeeded = false;
    var body: ?[]const u8 = null;
    var hop: u8 = 0;
    while (true) {
        if (cancelled(cancel_epoch)) return cancelled_fetch;
        const current = url_buf[0..current_len];
        var pin_buf: [512]u8 = undefined;
        const pin = targets.vetScrape(current, &pin_buf) orelse {
            logs.pushLog("warn", "scrape", "Blocked private network target", false);
            return refused_fetch;
        };
        body = plainFetch(current, post, out_buf, &hdr_buf, &hdr_len, &status, &plain_succeeded, cancel_epoch, if (pin.len > 0) pin else null);
        if (cancelled(cancel_epoch)) return cancelled_fetch;
        if (!http_pure.isRedirect(status)) break;
        if (hop == http_pure.max_redirects) return .{ .outcome = .http_error };
        const loc = target_policy.locationHeader(hdr_buf[0..hdr_len]) orelse return .{ .outcome = .http_error };
        var next_buf: [2048]u8 = undefined;
        const next = target_policy.joinRedirect(current, loc, &next_buf) orelse return refused_fetch;
        if (next.len > url_buf.len) return refused_fetch;
        @memcpy(url_buf[0..next.len], next);
        current_len = next.len;
        if (http_pure.redirectDropsBody(status, post != null, false)) post = null;
        hop += 1;
    }

    // Names match the browser-bridge call the feature tests lock in: the URL is
    // the hop that was fetched (already vetted), and the body is dropped after
    // a 301/302/303.
    const url = url_buf[0..current_len];
    const post_body = post;
    const body_head = if (body) |b| b[0..@min(b.len, 16 * 1024)] else "";
    const headers = hdr_buf[0..hdr_len];

    // A redirect body is not content; the loop above only arrives here for a
    // non-redirect status. A 4xx/5xx document is never scraper content either.
    switch (policy.classifyPlain(.{
        .succeeded = plain_succeeded,
        .status = status,
        .challenge = pure.needsBrowser(status, headers, body_head),
    })) {
        .content => return .{ .outcome = .ok, .body = body orelse out_buf[0..0] },
        .http_error => return .{ .outcome = .http_error },
        .unreachable_host => return .{ .outcome = .unreachable_host },
        .challenge => {},
    }

    // Blocked. Every browser tier below comes from policy.browserTiers, which
    // is empty unless the user opted in. The URL is the hop that was actually
    // fetched, already vetted above.
    const avail = availability();
    const plan = policy.browserTiers(avail);
    var tried: usize = 0;
    for (plan.slice()) |tier| {
        if (cancelled(cancel_epoch)) return cancelled_fetch;
        tried += 1;
        switch (tier) {
            .plain => unreachable,
            // The user's own paired browser. It never prompts from here (an
            // origin the user has not allowed answers "not allowed" at once).
            .paired_browser => if (browser_fetch.fetchText(url, post_body, out_buf, cancel_epoch)) |t| {
                if (cancelled(cancel_epoch)) return cancelled_fetch;
                const head = t.body[0..@min(t.body.len, 16 * 1024)];
                if (policy.browserAnswerUsable(t.status, t.body.len, pure.needsBrowser(t.status, "", head))) {
                    logs.pushLog("info", "scrape", "Blocked: fetched through the paired browser", true);
                    return .{ .outcome = .ok, .tier = tier, .body = t.body };
                }
            },
            .antidetect_browser => {
                logs.pushLog("info", "scrape", "Blocked — retrying through the anti-detect browser", true);
                const unblocked = browser.fetchHtmlWithCancellation(url, post_body, out_buf, cancel_epoch);
                if (cancelled(cancel_epoch)) return cancelled_fetch;
                if (unblocked) |html| return .{ .outcome = .ok, .tier = tier, .body = html };
            },
        }
    }

    // Never hand the original challenge/error document to a parser as though
    // it were the requested content.
    const outcome = policy.blockedOutcome(avail, tried);
    logs.pushLog("warn", "scrape", switch (outcome) {
        .blocked_opt_in_required => "Blocked page; browser fallback is off (opt in under Network settings)",
        .blocked_no_browser => "Blocked page; no paired browser or installed browser engine",
        else => "Blocked page; the browser fallback also failed",
    }, false);
    return .{ .outcome = outcome };
}
