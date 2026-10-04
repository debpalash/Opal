// Unit tests for the pure sniffer logic. Run with `npm test` (node >= 22.18
// strips the TypeScript types itself, so there is no build step and no
// dependency).
import test from "node:test";
import assert from "node:assert/strict";
import {
  MAX_PER_TAB,
  MAX_TS_WITHOUT_MANIFEST,
  addCandidate,
  buildMediaPayload,
  buildSharePayload,
  clipBytes,
  wireCandidate,
  candidateId,
  classifyContentType,
  classifyUrl,
  describeCandidate,
  isNoiseUrl,
  makeCandidate,
  masterScore,
  pickHeaders,
  sortCandidates,
} from "../src/sniffer.ts";

const cand = (url, kind, extra = {}) =>
  makeCandidate({ url, kind, now: extra.now ?? 1, headers: extra.headers, pageUrl: extra.pageUrl, size: extra.size });

test("classifyUrl: the stream extensions", () => {
  assert.equal(classifyUrl("https://cdn.example/a/master.m3u8"), "hls");
  assert.equal(classifyUrl("https://cdn.example/a/master.M3U8?token=abc&x=1"), "hls");
  assert.equal(classifyUrl("https://cdn.example/stream.mpd"), "dash");
  assert.equal(classifyUrl("https://cdn.example/v.mp4"), "mp4");
  assert.equal(classifyUrl("https://cdn.example/v.webm#t=10"), "webm");
  assert.equal(classifyUrl("https://cdn.example/v.mkv"), "mkv");
  assert.equal(classifyUrl("https://cdn.example/song.mp3"), "audio");
  assert.equal(classifyUrl("https://cdn.example/seg-1.ts"), "ts");
});

test("classifyUrl: not streams", () => {
  assert.equal(classifyUrl("https://example.com/"), null);
  assert.equal(classifyUrl("https://example.com/page.html"), null);
  assert.equal(classifyUrl("https://example.com/app.js?file=a.mp4"), null);
  assert.equal(classifyUrl("https://example.com/dir.mp4/index"), null);
  assert.equal(classifyUrl("https://example.com/a.m4s"), null);
  assert.equal(classifyUrl("https://example.com/video/init.mp4"), null);
  assert.equal(classifyUrl("https://example.com/video/seg-12.mp4"), null);
});

test("classifyUrl: only http(s)", () => {
  assert.equal(classifyUrl("blob:https://example.com/uuid"), null);
  assert.equal(classifyUrl("data:video/mp4;base64,AAAA"), null);
  assert.equal(classifyUrl("file:///tmp/a.mp4"), null);
  assert.equal(classifyUrl("javascript:alert(1)"), null);
  assert.equal(classifyUrl("not a url"), null);
  assert.equal(classifyUrl(""), null);
});

test("classifyContentType: extension-less streams", () => {
  assert.equal(classifyContentType("application/vnd.apple.mpegurl"), "hls");
  assert.equal(classifyContentType("application/x-mpegURL; charset=utf-8"), "hls");
  assert.equal(classifyContentType("application/dash+xml"), "dash");
  assert.equal(classifyContentType("video/mp4"), "mp4");
  assert.equal(classifyContentType("video/webm"), "webm");
  assert.equal(classifyContentType("video/mp2t"), "ts");
  assert.equal(classifyContentType("audio/mpeg"), "audio");
  assert.equal(classifyContentType("video/x-flv"), "other");
  assert.equal(classifyContentType("text/html"), null);
  assert.equal(classifyContentType("image/png"), null);
  assert.equal(classifyContentType(""), null);
});

test("isNoiseUrl: ad hosts, non-http(s), oversized", () => {
  assert.equal(isNoiseUrl("https://securepubads.g.doubleclick.net/a.mp4"), true);
  assert.equal(isNoiseUrl("https://imasdk.googleapis.com/x.mp4"), true);
  assert.equal(isNoiseUrl("ftp://example.com/a.mp4"), true);
  assert.equal(isNoiseUrl("https://cdn.example.com/a.mp4"), false);
  assert.equal(isNoiseUrl("http://192.168.1.20:8096/v.m3u8"), false);
  assert.equal(isNoiseUrl("https://cdn.example.com/" + "a".repeat(5000) + ".mp4"), true);
});

test("candidateId drops the fragment only", () => {
  assert.equal(candidateId("https://x.example/a.mp4#t=5"), "https://x.example/a.mp4");
  assert.equal(candidateId("https://x.example/a.m3u8?t=1#a"), "https://x.example/a.m3u8?t=1");
});

test("pickHeaders keeps Referer, Origin and User-Agent only, any case", () => {
  const h = pickHeaders([
    { name: "referer", value: "https://p.example/embed/1" },
    { name: "Origin", value: "https://p.example" },
    { name: "USER-AGENT", value: "UA/1" },
    { name: "Cookie", value: "secret=1" },
    { name: "Authorization", value: "Bearer abc" },
    { name: "Range", value: "bytes=0-" },
  ]);
  assert.deepEqual(h, { referer: "https://p.example/embed/1", origin: "https://p.example", ua: "UA/1" });
  assert.deepEqual(pickHeaders(undefined), { referer: "", origin: "", ua: "" });
  assert.deepEqual(pickHeaders([{ name: "Referer" }]), { referer: "", origin: "", ua: "" });
});

test("makeCandidate never carries cookies and strips the fragment", () => {
  const c = makeCandidate({
    url: "https://cdn.example/v.mp4#frag",
    kind: "mp4",
    headers: [{ name: "Cookie", value: "a=b" }, { name: "Referer", value: "https://p.example/" }],
    now: 5,
  });
  assert.equal(c.url, "https://cdn.example/v.mp4");
  assert.equal(c.referer, "https://p.example/");
  assert.equal(JSON.stringify(c).includes("a=b"), false);
});

test("addCandidate: the same URL is one candidate and fills in what was empty", () => {
  let list = [];
  list = addCandidate(list, cand("https://cdn.example/v.mp4", "mp4", { now: 1 }));
  list = addCandidate(
    list,
    cand("https://cdn.example/v.mp4#x", "mp4", { now: 9, headers: [{ name: "Referer", value: "https://p.example/e" }] }),
  );
  assert.equal(list.length, 1);
  assert.equal(list[0].referer, "https://p.example/e");
  assert.equal(list[0].seenAt, 9);
  // A later sighting never overwrites a header already captured.
  list = addCandidate(
    list,
    cand("https://cdn.example/v.mp4", "mp4", { now: 10, headers: [{ name: "Referer", value: "https://other.example/" }] }),
  );
  assert.equal(list[0].referer, "https://p.example/e");
});

test("addCandidate does not mutate its input", () => {
  const before = [cand("https://cdn.example/a.mp4", "mp4")];
  const snapshot = JSON.stringify(before);
  addCandidate(before, cand("https://cdn.example/b.mp4", "mp4"));
  addCandidate(before, cand("https://cdn.example/a.mp4", "mp4", { now: 99 }));
  assert.equal(JSON.stringify(before), snapshot);
});

test("addCandidate: a stream's segment flood collapses once a playlist exists", () => {
  let list = [];
  for (let i = 0; i < 50; i++) list = addCandidate(list, cand(`https://cdn.example/seg-${i}.ts`, "ts", { now: i }));
  assert.equal(list.length, MAX_TS_WITHOUT_MANIFEST);
  list = addCandidate(list, cand("https://cdn.example/master.m3u8", "hls", { now: 100 }));
  assert.deepEqual(list.map((c) => c.kind), ["hls"]);
  for (let i = 50; i < 100; i++) list = addCandidate(list, cand(`https://cdn.example/seg-${i}.ts`, "ts", { now: i }));
  assert.deepEqual(list.map((c) => c.kind), ["hls"]);
});

test("addCandidate: capped per tab, dropping the weakest oldest first", () => {
  let list = [];
  list = addCandidate(list, cand("https://cdn.example/master.m3u8", "hls", { now: 1 }));
  for (let i = 0; i < MAX_PER_TAB + 10; i++) {
    list = addCandidate(list, cand(`https://cdn.example/clip${i}.mp3`, "audio", { now: 10 + i }));
  }
  assert.equal(list.length, MAX_PER_TAB);
  // The manifest outranks every audio file, so it survives however old it is.
  assert.ok(list.some((c) => c.kind === "hls"));
  // The oldest audio went first.
  assert.ok(!list.some((c) => c.url.endsWith("clip0.mp3")));
  assert.ok(list.some((c) => c.url.endsWith(`clip${MAX_PER_TAB + 9}.mp3`)));
});

test("sortCandidates: manifests, then files, then audio; masters over variants", () => {
  const list = [
    cand("https://cdn.example/seg.ts", "ts", { now: 1 }),
    cand("https://cdn.example/song.mp3", "audio", { now: 2 }),
    cand("https://cdn.example/720p.m3u8", "hls", { now: 3 }),
    cand("https://cdn.example/v.mp4", "mp4", { now: 4 }),
    cand("https://cdn.example/master.m3u8", "hls", { now: 2 }),
  ];
  const sorted = sortCandidates(list);
  assert.deepEqual(
    sorted.map((c) => c.url.split("/").pop()),
    ["master.m3u8", "720p.m3u8", "v.mp4", "song.mp3", "seg.ts"],
  );
  // Input order is untouched.
  assert.equal(list[0].kind, "ts");
});

test("masterScore: index and master beat resolution variants", () => {
  assert.ok(masterScore("https://c.example/hls/master.m3u8") > masterScore("https://c.example/hls/1080p.m3u8"));
  assert.ok(masterScore("https://c.example/hls/index.m3u8") > masterScore("https://c.example/hls/index_2.m3u8"));
  assert.equal(masterScore("not a url"), 0);
});

test("buildMediaPayload: one candidate, only set fields, headers validated", () => {
  const c = cand("https://cdn.example/m.m3u8?t=1", "hls", {
    pageUrl: "https://site.example/watch/1",
    headers: [
      { name: "Referer", value: "https://embed.example/p/1" },
      { name: "Origin", value: "https://embed.example" },
      { name: "User-Agent", value: "Mozilla/5.0 Test" },
    ],
  });
  const p = buildMediaPayload(c, "play", { title: "A clip", art: "https://site.example/p.jpg" });
  assert.deepEqual(p, {
    page_url: "https://site.example/watch/1",
    title: "A clip",
    art: "https://site.example/p.jpg",
    action: "play",
    candidates: [
      {
        url: "https://cdn.example/m.m3u8?t=1",
        kind: "hls",
        referer: "https://embed.example/p/1",
        origin: "https://embed.example",
        ua: "Mozilla/5.0 Test",
      },
    ],
  });
});

test("buildMediaPayload drops bad optional fields and refuses a bad URL", () => {
  const bad = cand("https://cdn.example/a.mp4", "mp4", {
    headers: [
      { name: "Referer", value: "javascript:alert(1)" },
      { name: "User-Agent", value: "a\r\nX-Evil: 1" },
    ],
  });
  const p = buildMediaPayload(bad, "queue");
  assert.equal(p.action, "queue");
  assert.deepEqual(p.candidates[0], { url: "https://cdn.example/a.mp4", kind: "mp4" });
  assert.equal(buildMediaPayload({ ...bad, url: "file:///etc/passwd" }, "play"), null);
  assert.equal(buildMediaPayload({ ...bad, url: "https://cdn.example/" + "a".repeat(5000) }, "play"), null);
  assert.equal(buildMediaPayload(bad, "play", { title: "x".repeat(1000) }).title.length, 256);
});

test("describeCandidate: host and file name", () => {
  const d = describeCandidate(cand("https://cdn.example:8443/dir/master.m3u8?t=1", "hls"));
  assert.deepEqual(d, { host: "cdn.example:8443", name: "master.m3u8" });
});

const facts = (extra = {}) => ({
  url: "https://example.com/watch?v=1",
  title: "Dune (2021)",
  og: { "og:title": "Dune", "og:image": "https://example.com/p.jpg" },
  jsonld: ['{"@type":"Movie"}'],
  text: "Some page text",
  ...extra,
});

test("buildSharePayload: not shared with agents unless asked, only set fields", () => {
  const m = cand("https://cdn.example/m.m3u8?t=1", "hls", {
    headers: [{ name: "Referer", value: "https://embed.example/p/1" }],
  });
  const p = buildSharePayload(facts(), [m], false);
  assert.equal(p.shared_with_agents, false);
  assert.equal(p.url, "https://example.com/watch?v=1");
  assert.deepEqual(p.candidates, [{ url: "https://cdn.example/m.m3u8?t=1", kind: "hls", referer: "https://embed.example/p/1" }]);
  assert.equal(buildSharePayload(facts(), [], true).shared_with_agents, true);
  // Anything that is not literally true stays false.
  assert.equal(buildSharePayload(facts(), [], "yes").shared_with_agents, false);
});

test("buildSharePayload: refuses a page address that cannot be sent", () => {
  assert.equal(buildSharePayload(facts({ url: "javascript:alert(1)" }), [], false), null);
  assert.equal(buildSharePayload(facts({ url: "file:///etc/passwd" }), [], false), null);
  assert.equal(buildSharePayload(facts({ url: "https://e.com/" + "a".repeat(3000) }), [], false), null);
});

test("buildSharePayload: text capped at 8 KB bytes, og and jsonld bounded, no extra fields", () => {
  const og = {};
  for (let i = 0; i < 40; i++) og["k" + i] = "v".repeat(1000);
  const p = buildSharePayload(
    facts({ text: "é".repeat(9000), og, jsonld: ["a", "b", "c", "d", "x".repeat(5000)] }),
    [],
    false,
  );
  assert.ok(new TextEncoder().encode(p.text).length <= 8192);
  assert.equal(Object.keys(p.og).length, 12);
  assert.ok(Object.values(p.og).every((v) => v.length <= 300));
  assert.equal(p.jsonld.length, 3);
  assert.deepEqual(Object.keys(p).sort(), ["candidates", "jsonld", "og", "shared_with_agents", "text", "title", "url"]);
});

test("buildSharePayload: at most eight candidates and bad ones are dropped", () => {
  const list = [];
  for (let i = 0; i < 12; i++) list.push(cand(`https://cdn.example/v${i}.mp4`, "mp4"));
  list.unshift({ ...cand("https://cdn.example/x.mp4", "mp4"), url: "file:///etc/passwd" });
  const p = buildSharePayload(facts(), list, false);
  assert.equal(p.candidates.length, 8);
  assert.ok(p.candidates.every((c) => c.url.startsWith("https://")));
});

test("clipBytes never splits a character; wireCandidate rejects bad URLs", () => {
  assert.equal(clipBytes("ééé", 5), "éé");
  assert.equal(clipBytes("abc", 10), "abc");
  assert.equal(wireCandidate({ ...cand("https://cdn.example/a.mp4", "mp4"), url: "data:text/html,x" }), null);
});
