// Unit tests for the pure fetch-through-this-browser rules. `npm test`.
import test from "node:test";
import assert from "node:assert/strict";
import {
  ALLOW_TTL_MS,
  MAX_URL,
  addEntry,
  badUrlReason,
  charsetOf,
  clipUtf8,
  decide,
  failureQuery,
  finalAllowed,
  hostOf,
  isAllowed,
  isPrivateTarget,
  liveEntries,
  normalizeOriginInput,
  originOf,
  publicHost,
  removeEntry,
  resultQuery,
  textContentType,
  touchEntry,
} from "../src/fetch_policy.ts";

const NOW = 1_700_000_000_000;
const job = (over = {}) => ({ id: 1, method: "GET", url: "https://example.org/a", body: "", prompt: true, ...over });

test("urls: http(s) only, no credentials, bounded, no control characters", () => {
  assert.equal(badUrlReason("https://example.org/a?b=c"), null);
  assert.equal(badUrlReason("http://example.org:8080/"), null);
  assert.equal(badUrlReason("https://example.org/@user?e=a@b"), null);
  for (const bad of ["", "ftp://example.org/", "file:///etc/passwd", "javascript:alert(1)", "data:text/html,hi", "//example.org/"]) {
    assert.notEqual(badUrlReason(bad), null, bad);
  }
  assert.equal(badUrlReason("https://user:pw@example.org/"), "credentials");
  assert.equal(badUrlReason("http://example.org:80@evil.test/"), "credentials");
  assert.equal(badUrlReason("https://example.org/a b"), "bad character");
  assert.equal(badUrlReason("https://example.org/a\r\nHost: x"), "bad character");
  assert.equal(badUrlReason("https://example.org\\@evil.test/"), "bad character");
  assert.equal(badUrlReason("https:///path"), "no host");
  assert.equal(badUrlReason("https://e.org/" + "a".repeat(MAX_URL)), "too long");
});

test("origins: normalized, default ports dropped, user input forgiving", () => {
  assert.equal(originOf("https://Example.ORG/a/b?c#d"), "https://example.org");
  assert.equal(originOf("https://example.org:443/"), "https://example.org");
  assert.equal(originOf("http://example.org:8080/x"), "http://example.org:8080");
  assert.equal(originOf("ftp://example.org/"), null);
  assert.equal(normalizeOriginInput("example.org"), "https://example.org");
  assert.equal(normalizeOriginInput(" http://nas.local:8096/web/index.html "), "http://nas.local:8096");
  assert.equal(normalizeOriginInput("javascript:alert(1)"), null);
  assert.equal(normalizeOriginInput("a b.org"), null);
  assert.equal(normalizeOriginInput("https://u:p@example.org"), null);
  assert.equal(normalizeOriginInput(""), null);
});

test("private targets: loopback, LAN, link-local, local names and IP literals are not public", () => {
  for (const u of [
    "http://127.0.0.1/", "http://127.0.0.1:41595/api/status", "http://localhost/", "http://[::1]/",
    "http://192.168.1.1/", "http://10.0.0.5/", "http://172.16.0.9/", "http://169.254.169.254/latest/meta-data/",
    "http://nas.local/", "http://printer/", "http://foo.internal/", "http://0x7f.0.0.1/", "http://2130706433/",
    "http://app.localhost/", "http://[fe80::1]/", "http://router.lan:8080/", "http://127.1/", "http://0/",
  ]) {
    assert.ok(isPrivateTarget(u), u);
  }
  for (const u of ["https://example.org/", "https://www.example.com:8443/x", "http://sub.domain.co.uk/", "https://eztvx.to/"]) {
    assert.ok(!isPrivateTarget(u), u);
  }
  assert.equal(hostOf("http://[::1]:80/"), "::1");
  assert.ok(!publicHost(""));
});

test("allow list: add, remove, expire after 30 days unused, touch renews", () => {
  let list = addEntry([], "https://example.org", NOW);
  assert.ok(isAllowed(list, "https://example.org", NOW + 1));
  assert.ok(!isAllowed(list, "https://other.org", NOW));
  assert.ok(!isAllowed(list, "http://example.org", NOW), "scheme is part of the origin");
  assert.ok(!isAllowed(list, "https://example.org:8443", NOW), "port is part of the origin");
  assert.ok(!isAllowed(list, "https://sub.example.org", NOW), "subdomains are not implied");
  assert.equal(liveEntries(list, NOW + ALLOW_TTL_MS + 1).length, 0);
  list = touchEntry(list, "https://example.org", NOW + ALLOW_TTL_MS - 1);
  assert.ok(isAllowed(list, "https://example.org", NOW + ALLOW_TTL_MS + 1000));
  list = removeEntry(list, "https://example.org");
  assert.equal(list.length, 0);
  // Adding twice keeps one entry; a private origin is flagged.
  list = addEntry(addEntry([], "http://nas.local:8096", NOW), "http://nas.local:8096", NOW);
  assert.equal(list.length, 1);
  assert.equal(list[0].private, true);
});

test("decide: an origin not on the list is asked about only when the caller may prompt, otherwise denied", () => {
  const empty = [];
  assert.deepEqual(decide(job(), empty, NOW), { kind: "ask", origin: "https://example.org", private: false });
  assert.deepEqual(decide(job({ prompt: false }), empty, NOW), { kind: "deny", code: "origin_not_allowed" });
  const allowed = addEntry([], "https://example.org", NOW);
  assert.deepEqual(decide(job(), allowed, NOW), { kind: "allow", origin: "https://example.org" });
  assert.deepEqual(decide(job({ prompt: false }), allowed, NOW), { kind: "allow", origin: "https://example.org" });
  // The decision is per origin, not per host name.
  assert.equal(decide(job({ url: "https://example.org:8443/" }), allowed, NOW).kind, "ask");
  assert.equal(decide(job({ url: "http://example.org/" }), allowed, NOW).kind, "ask");
});

test("decide: private targets are never run for an origin the user did not name", () => {
  assert.deepEqual(decide(job({ url: "http://127.0.0.1:41595/api/status", prompt: false }), [], NOW), { kind: "deny", code: "private_target" });
  const d = decide(job({ url: "http://192.168.1.1/" }), [], NOW);
  assert.equal(d.kind, "ask");
  assert.equal(d.private, true);
  const named = addEntry([], "http://192.168.1.1", NOW);
  assert.equal(decide(job({ url: "http://192.168.1.1/admin" }), named, NOW).kind, "allow");
  // Naming one private origin does not open its neighbours.
  assert.equal(decide(job({ url: "http://192.168.1.2/" , prompt: false }), named, NOW).kind, "deny");
});

test("decide: a POST only runs for an origin already on the list and is never asked about", () => {
  const post = job({ method: "POST", body: "layout=def_wlinks", prompt: true });
  assert.deepEqual(decide(post, [], NOW), { kind: "deny", code: "origin_not_allowed" });
  assert.equal(decide(post, addEntry([], "https://example.org", NOW), NOW).kind, "allow");
  assert.equal(decide(job({ body: "x=1" }), addEntry([], "https://example.org", NOW), NOW).kind, "deny", "GET with a body");
  assert.equal(decide(job({ method: "POST", body: "a".repeat(2049) }), addEntry([], "https://example.org", NOW), NOW).kind, "deny");
  assert.deepEqual(decide(job({ method: "DELETE" }), [], NOW), { kind: "deny", code: "unsupported" });
});

test("decide: hostile URLs are refused before any consent question", () => {
  for (const url of ["file:///etc/passwd", "https://user:pw@example.org/", "javascript:alert(1)", "https://example.org/a b", ""]) {
    assert.deepEqual(decide(job({ url }), [], NOW), { kind: "deny", code: "bad_request" }, url);
  }
});

test("redirects: the final page is read only if its origin was allowed", () => {
  const list = addEntry([], "https://example.org", NOW);
  assert.ok(finalAllowed("https://example.org", "https://example.org/b?x=1", list, NOW));
  assert.ok(!finalAllowed("https://example.org", "https://evil.test/", list, NOW));
  assert.ok(!finalAllowed("https://example.org", "http://169.254.169.254/latest/", list, NOW));
  assert.ok(!finalAllowed("https://example.org", "file:///etc/passwd", list, NOW));
  const both = addEntry(list, "https://cdn.example.net", NOW);
  assert.ok(finalAllowed("https://example.org", "https://cdn.example.net/x", both, NOW));
});

test("content types and charsets", () => {
  for (const ok of ["text/html; charset=utf-8", "TEXT/PLAIN", "application/json", "application/ld+json", "application/atom+xml", "application/xhtml+xml", "text/csv"]) {
    assert.ok(textContentType(ok), ok);
  }
  for (const bad of ["", "image/png", "video/mp4", "application/octet-stream", "application/pdf", "application/zip", "audio/mpeg", "texty/html", "application/json2"]) {
    assert.ok(!textContentType(bad), bad);
  }
  assert.equal(charsetOf("text/html; charset=ISO-8859-1"), "iso-8859-1");
  assert.equal(charsetOf('text/html; charset="utf-8"'), "utf-8");
  assert.equal(charsetOf("text/html; charset=nonsense-9"), "utf-8");
  assert.equal(charsetOf("text/html"), "utf-8");
});

test("clipUtf8 never ends inside a character and reports truncation", () => {
  const enc = new TextEncoder();
  const small = clipUtf8(enc.encode("hello"), 10);
  assert.equal(small.truncated, false);
  const bytes = enc.encode("aé€𝄞"); // 1 + 2 + 3 + 4 bytes
  for (let max = 1; max < bytes.length; max++) {
    const c = clipUtf8(bytes, max);
    assert.equal(c.truncated, true);
    new TextDecoder("utf-8", { fatal: true }).decode(c.bytes); // throws on a split character
    assert.ok(c.bytes.length <= max);
  }
});

test("answers: success carries status, type, address and truncation; failure only a code", () => {
  assert.equal(
    resultQuery({ status: 200, contentType: "text/html; charset=utf-8", finalUrl: "https://example.org/a?x=1", truncated: false }),
    "ok=1&status=200&ctype=text%2Fhtml%3B%20charset%3Dutf-8&url=https%3A%2F%2Fexample.org%2Fa%3Fx%3D1&truncated=0",
  );
  assert.ok(resultQuery({ status: 200, contentType: "text/plain", finalUrl: "https://e.org/", truncated: true }).endsWith("truncated=1"));
  // A long final address is cut to origin and path so the request head still fits.
  const long = "https://example.org/p?" + "q".repeat(5000);
  const q = resultQuery({ status: 200, contentType: "text/plain", finalUrl: long, truncated: false });
  assert.ok(q.length < 600, String(q.length));
  assert.ok(q.includes("url=https%3A%2F%2Fexample.org%2Fp&"));
  assert.equal(failureQuery("origin_not_allowed"), "ok=0&code=origin_not_allowed");
});
