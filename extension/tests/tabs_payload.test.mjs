// Unit tests for the pure tab-list payload. `npm test`.
import test from "node:test";
import assert from "node:assert/strict";
import { MAX_TABS, MAX_TITLE, buildTabsPayload, scrubTitle, trimUrl } from "../src/tabs_payload.ts";

test("trimUrl keeps host and path, drops query, fragment and credentials, refuses non-web schemes", () => {
  assert.equal(trimUrl("https://example.org:8443/watch/abc?token=SECRET&t=5#frag"), "https://example.org:8443/watch/abc");
  assert.equal(trimUrl("http://example.org"), "http://example.org/");
  for (const bad of ["chrome://settings/", "file:///etc/passwd", "javascript:alert(1)", "about:blank", "chrome-extension://abc/x.html", "https://u:p@example.org/", "nonsense", ""]) {
    assert.equal(trimUrl(bad), null, bad);
  }
});

test("buildTabsPayload: web tabs only, no incognito, no secrets, bounded titles and count", () => {
  const p = buildTabsPayload([
    { title: "Video\n page", url: "https://example.org/watch?token=SECRET#x", audible: true, active: true },
    { title: "Private", url: "https://example.org/secret", incognito: true },
    { title: "Settings", url: "chrome://settings/" },
    { title: "t".repeat(500), url: "https://example.org/long" },
    { url: "https://example.org/untitled" },
  ]);
  assert.equal(p.tabs.length, 3);
  assert.deepEqual(p.tabs[0], { title: "Video page", url: "https://example.org/watch", audible: true, active: true });
  assert.equal(p.tabs[1].title.length, MAX_TITLE);
  assert.equal(p.tabs[2].title, "");
  assert.ok(!JSON.stringify(p).includes("SECRET"));
  assert.ok(!JSON.stringify(p).includes("incognito"));
  assert.ok(!JSON.stringify(p).includes("/secret"));
  const many = buildTabsPayload(Array.from({ length: 200 }, (_, i) => ({ title: `t${i}`, url: `https://e.org/${i}` })));
  assert.equal(many.tabs.length, MAX_TABS);
  assert.deepEqual(buildTabsPayload([]), { tabs: [] });
});

test("a title that is the address does not carry the query string out", () => {
  const p = buildTabsPayload([
    { title: "127.0.0.1:8812/echo?token=ABC", url: "http://127.0.0.1:8812/echo?token=ABC" },
    { title: "https://example.org/a?x=SECRET#frag", url: "https://example.org/a?x=SECRET#frag" },
    { title: "Plain title", url: "https://example.org/b?x=1" },
  ]);
  assert.equal(p.tabs[0].title, "127.0.0.1:8812/echo");
  assert.equal(p.tabs[1].title, "https://example.org/a");
  assert.equal(p.tabs[2].title, "Plain title");
  assert.ok(!JSON.stringify(p).includes("SECRET"));
  assert.ok(!JSON.stringify(p).includes("ABC"));
  assert.equal(scrubTitle("x", "https://e.org/", "https://e.org/"), "x");
});
