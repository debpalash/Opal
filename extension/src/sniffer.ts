/**
 * Media sniffer: the pure parts. Classify a request as a playable stream, keep a
 * bounded, de-duplicated list per tab, and build the payload for Opal's
 * `POST /api/browser/media`.
 *
 * Nothing in here touches `chrome.*`, so it runs under plain node for the unit
 * tests (extension/tests/sniffer.test.mjs, `npm test`) and is shared by the
 * background worker, which feeds it `webRequest` events. Keep it free of
 * imports and of syntax node cannot strip (no enums, no namespaces).
 *
 * What a page controls here is untrusted: URLs and header values come from
 * whatever the page requested. The server validates again (src/services/
 * browser_link_pure.zig); this side keeps the list small and sensible.
 */

export type StreamKind = "hls" | "dash" | "mp4" | "webm" | "mkv" | "audio" | "ts" | "other";

export interface Candidate {
  /** Stable key: the URL without its fragment. */
  id: string;
  url: string;
  kind: StreamKind;
  /** What the browser itself sent. Empty when it sent none. */
  referer: string;
  origin: string;
  ua: string;
  /** The top page the tab was on when the request was seen. */
  pageUrl: string;
  /** The frame (often an iframe player) that issued the request. */
  frameUrl: string;
  seenAt: number;
  /** Response Content-Length when known; used to ignore tiny beacons. */
  size?: number;
}

/** Candidates kept per tab. Segment floods are collapsed long before this. */
export const MAX_PER_TAB = 24;
/** Bare transport-stream segments kept while no playlist has been seen. */
export const MAX_TS_WITHOUT_MANIFEST = 2;
/** Matches the server: a URL longer than this is not sent. */
export const MAX_URL = 4096;

/** What 'Detect media' asks for, at the moment the user turns it on: access to
 *  all sites (the extension's optional host permissions). Nothing is observed
 *  until this is granted. `webRequest` itself is a manifest permission. */
export const SNIFFER_PERMISSIONS = {
  origins: ["http://*/*", "https://*/*"],
};

const EXT_KIND: Record<string, StreamKind> = {
  m3u8: "hls",
  mpd: "dash",
  mp4: "mp4",
  m4v: "mp4",
  mov: "mp4",
  webm: "webm",
  mkv: "mkv",
  mp3: "audio",
  m4a: "audio",
  aac: "audio",
  flac: "audio",
  ogg: "audio",
  opus: "audio",
  wav: "audio",
  ts: "ts",
};

/** Chunks of an adaptive stream, never playable alone. */
const SEGMENT_PATH = /\.(m4s|m4f|cmfv|cmfa|fmp4)$/i;
/** Init and numbered fragments that happen to end in .mp4. */
const FRAGMENT_NAME = /(^|[\/_-])(init|seg|segment|chunk|frag|fragment)[-_]?\d*\.mp4$/i;

function parse(raw: string): URL | null {
  try {
    const u = new URL(raw);
    return u.protocol === "http:" || u.protocol === "https:" ? u : null;
  } catch {
    return null;
  }
}

/** Kind by file extension, or null when the URL does not look like a stream. */
export function classifyUrl(raw: string): StreamKind | null {
  const u = parse(raw);
  if (!u) return null;
  const path = u.pathname;
  if (SEGMENT_PATH.test(path) || FRAGMENT_NAME.test(path)) return null;
  const dot = path.lastIndexOf(".");
  if (dot < 0 || dot < path.lastIndexOf("/")) return null;
  return EXT_KIND[path.slice(dot + 1).toLowerCase()] ?? null;
}

/** Kind by response Content-Type, for streams whose URL has no extension. */
export function classifyContentType(contentType: string): StreamKind | null {
  const ct = contentType.split(";")[0].trim().toLowerCase();
  if (!ct) return null;
  if (
    ct === "application/vnd.apple.mpegurl" ||
    ct === "application/x-mpegurl" ||
    ct === "audio/mpegurl" ||
    ct === "audio/x-mpegurl"
  )
    return "hls";
  if (ct === "application/dash+xml") return "dash";
  if (ct === "video/mp4") return "mp4";
  if (ct === "video/webm") return "webm";
  if (ct === "video/x-matroska") return "mkv";
  if (ct === "video/mp2t") return "ts";
  if (ct.startsWith("audio/")) return "audio";
  if (ct.startsWith("video/")) return "other";
  return null;
}

const NOISE_HOSTS = [
  "doubleclick.net",
  "googlesyndication.com",
  "googleadservices.com",
  "adservice.google.",
  "imasdk.googleapis.com",
  "moatads.com",
  "adnxs.com",
  "taboola.com",
  "outbrain.com",
  "scorecardresearch.com",
  "adsafeprotected.com",
  "innovid.com",
];

/** Ad and measurement hosts, and anything that is not http(s) or too long to send. */
export function isNoiseUrl(raw: string): boolean {
  if (raw.length > MAX_URL) return true;
  const u = parse(raw);
  if (!u) return true;
  const host = u.hostname.toLowerCase();
  return NOISE_HOSTS.some((n) => host === n || host.endsWith("." + n) || host.includes(n));
}

export function candidateId(raw: string): string {
  const i = raw.indexOf("#");
  return i < 0 ? raw : raw.slice(0, i);
}

export function kindRank(kind: StreamKind): number {
  switch (kind) {
    case "hls":
    case "dash":
      return 4;
    case "mp4":
    case "webm":
    case "mkv":
      return 3;
    case "audio":
      return 2;
    case "other":
      return 1;
    default:
      return 0;
  }
}

/** Guess master-vs-variant from the file name. The sniffer never reads the
 *  playlist, so this is a heuristic: a master is usually called master/index/
 *  playlist/manifest, a variant carries a resolution or bitrate. */
export function masterScore(raw: string): number {
  const u = parse(raw);
  if (!u) return 0;
  const name = u.pathname.slice(u.pathname.lastIndexOf("/") + 1).toLowerCase();
  let score = 0;
  if (/(master|playlist|manifest|index|main|all)\b/.test(name)) score += 2;
  if (/(\d{3,4}p|[_-]\d{3,4}k|[_-]\d+\.m3u8|chunk|variant|level|rendition|audio|sub)/.test(name)) score -= 2;
  return score;
}

/** Best first: manifests over files over audio over segments, masters over
 *  variants, newest first within a tie. Does not mutate its input. */
export function sortCandidates(list: Candidate[]): Candidate[] {
  return [...list].sort(
    (a, b) =>
      kindRank(b.kind) - kindRank(a.kind) ||
      masterScore(b.url) - masterScore(a.url) ||
      b.seenAt - a.seenAt,
  );
}

function hasManifest(list: Candidate[]): boolean {
  return list.some((c) => c.kind === "hls" || c.kind === "dash");
}

/**
 * Add one sighting to a tab's list. Returns a new list (never mutates), or the
 * same list when nothing changed.
 *  - the same URL is one candidate; a later sighting only fills what was empty
 *  - once a playlist/manifest exists, loose `.ts` segments are dropped and no
 *    more are kept, because a stream is hundreds of them
 *  - without a manifest at most two `.ts` are kept
 *  - past `cap`, the lowest-ranked, oldest entries go first
 */
export function addCandidate(list: Candidate[], c: Candidate, cap: number = MAX_PER_TAB): Candidate[] {
  const existing = list.findIndex((x) => x.id === c.id);
  if (existing >= 0) {
    const prev = list[existing];
    const merged: Candidate = {
      ...prev,
      referer: prev.referer || c.referer,
      origin: prev.origin || c.origin,
      ua: prev.ua || c.ua,
      size: prev.size ?? c.size,
      seenAt: Math.max(prev.seenAt, c.seenAt),
    };
    const next = list.slice();
    next[existing] = merged;
    return next;
  }
  let next = list;
  if (c.kind === "ts") {
    if (hasManifest(list)) return list;
    if (list.filter((x) => x.kind === "ts").length >= MAX_TS_WITHOUT_MANIFEST) return list;
  } else if (c.kind === "hls" || c.kind === "dash") {
    next = list.filter((x) => x.kind !== "ts");
  }
  next = [...next, c];
  if (next.length > cap) {
    const sorted = sortCandidates(next);
    const keep = new Set(sorted.slice(0, cap).map((x) => x.id));
    next = next.filter((x) => keep.has(x.id));
  }
  return next;
}

/** Request headers the browser sent, reduced to the three Opal can replay. */
export function pickHeaders(
  headers: Array<{ name: string; value?: string }> | undefined,
): { referer: string; origin: string; ua: string } {
  const out = { referer: "", origin: "", ua: "" };
  for (const h of headers ?? []) {
    const name = h.name.toLowerCase();
    const value = h.value ?? "";
    if (name === "referer") out.referer = value;
    else if (name === "origin") out.origin = value;
    else if (name === "user-agent") out.ua = value;
  }
  return out;
}

export function makeCandidate(args: {
  url: string;
  kind: StreamKind;
  headers?: Array<{ name: string; value?: string }>;
  pageUrl?: string;
  frameUrl?: string;
  size?: number;
  now?: number;
}): Candidate {
  const h = pickHeaders(args.headers);
  return {
    id: candidateId(args.url),
    url: candidateId(args.url),
    kind: args.kind,
    referer: h.referer,
    origin: h.origin,
    ua: h.ua,
    pageUrl: args.pageUrl ?? "",
    frameUrl: args.frameUrl ?? "",
    seenAt: args.now ?? Date.now(),
    size: args.size,
  };
}

/** Short, human label for the side panel: host plus the file name. */
export function describeCandidate(c: Candidate): { host: string; name: string } {
  const u = parse(c.url);
  if (!u) return { host: "", name: c.url.slice(0, 60) };
  const last = u.pathname.slice(u.pathname.lastIndexOf("/") + 1) || u.pathname;
  return { host: u.host, name: last.length > 60 ? last.slice(0, 57) + "..." : last };
}

/** One candidate in the wire shape Opal's browser routes take: only the fields
 *  that are set. Null when the URL could not be accepted, so it is never sent. */
export function wireCandidate(c: Candidate): MediaPayload["candidates"][number] | null {
  if (!parse(c.url) || c.url.length > MAX_URL) return null;
  const cand: MediaPayload["candidates"][number] = { url: c.url, kind: c.kind };
  if (c.referer && parse(c.referer)) cand.referer = c.referer;
  if (c.origin && parse(c.origin)) cand.origin = c.origin;
  if (c.ua && c.ua.length <= 512 && !/[\u0000-\u001f\u007f]/.test(c.ua)) cand.ua = c.ua;
  return cand;
}

export interface MediaPayload {
  page_url: string;
  title: string;
  art: string;
  action: "play" | "queue";
  candidates: Array<{
    url: string;
    kind: StreamKind;
    referer?: string;
    origin?: string;
    ua?: string;
  }>;
}

/** Body for `POST /api/browser/media`: one candidate, with only the fields
 *  that are set (the server treats an absent field as empty). A candidate
 *  that could not be accepted is refused here rather than sent. */
export function buildMediaPayload(
  c: Candidate,
  action: "play" | "queue",
  page: { url?: string; title?: string; art?: string } = {},
): MediaPayload | null {
  const cand = wireCandidate(c);
  if (!cand) return null;
  const pageUrl = page.url || c.pageUrl;
  return {
    page_url: pageUrl && parse(pageUrl) && pageUrl.length <= 2048 ? pageUrl : "",
    title: (page.title ?? "").slice(0, 256),
    art: page.art && parse(page.art) ? page.art : "",
    action,
    candidates: [cand],
  };
}

// ── Add to Wanted ───────────────────────────────────────────────────────────

/** Body for `POST /api/browser/media` with `action: "add_to_wanted"`: the title
 *  the user typed or edited, and the page it came from for context. Opal parses
 *  the title ("Dune 2021", "Severance S02E03") with the same rules as the Wanted
 *  box in the app; this side only bounds it. null for an empty title. */
export function buildWantedPayload(title: string, pageUrl: string): { action: "add_to_wanted"; title: string; page_url: string } | null {
  // eslint-disable-next-line no-control-regex
  const t = title.replace(/[\u0000-\u001f\u007f]+/g, " ").replace(/\s+/g, " ").trim().slice(0, 150);
  if (!t) return null;
  return { action: "add_to_wanted", title: t, page_url: pageUrl && parse(pageUrl) && pageUrl.length <= 2048 ? pageUrl : "" };
}

/** A starting point for the editable title: a tab title usually carries the site
 *  name after a separator ("Dune (2021) - Watch Online | SomeSite"). The first
 *  segment is kept, "(2021)" loses its brackets, and the user edits the rest. */
export function suggestWantedTitle(tabTitle: string): string {
  let t = tabTitle.replace(/\s+/g, " ").trim();
  const seg = t.split(/\s+[-|\u2013\u2014\u00b7]\s+/)[0] ?? t;
  if (seg.length >= 2) t = seg;
  t = t.replace(/\((\d{4})\)\s*$/, "$1").replace(/\s*\((\d{4})\)\s*/, " $1 ");
  return t.replace(/\s+/g, " ").trim().slice(0, 150);
}

// ── Sharing a page with Opal ────────────────────────────────────────────────

/** Matches the server's bounds (src/services/browser_page_pure.zig). */
export const SHARE_MAX_TEXT = 8 * 1024;
export const SHARE_MAX_OG = 12;
export const SHARE_MAX_JSONLD = 3;
export const SHARE_MAX_JSONLD_LEN = 2048;
export const SHARE_MAX_CANDIDATES = 8;

/** What the page-reading step collects in the tab. Every field is page-controlled. */
export interface PageFacts {
  url: string;
  title: string;
  og: Record<string, string>;
  jsonld: string[];
  text: string;
}

export interface SharePayload {
  url: string;
  title: string;
  og: Record<string, string>;
  jsonld: string[];
  text: string;
  /** The "also let agents read this page" box. False unless the user ticked it. */
  shared_with_agents: boolean;
  candidates: MediaPayload["candidates"];
}

/** Cut to at most `max` UTF-8 bytes without splitting a character. */
export function clipBytes(s: string, max: number): string {
  const enc = new TextEncoder();
  if (enc.encode(s).length <= max) return s;
  let out = "";
  let used = 0;
  for (const ch of s) {
    const n = enc.encode(ch).length;
    if (used + n > max) break;
    out += ch;
    used += n;
  }
  return out;
}

/** The body for `POST /api/browser/page`. Built only when the user presses
 *  "Share this page with Opal"; never from a background event. Returns null when
 *  the page address itself cannot be sent. Candidates come from the tab's own
 *  sniffer list, best first, at most eight. */
export function buildSharePayload(
  facts: PageFacts,
  candidates: Candidate[],
  agents: boolean,
): SharePayload | null {
  if (!parse(facts.url) || facts.url.length > 2048) return null;
  const og: Record<string, string> = {};
  let n = 0;
  for (const [k, v] of Object.entries(facts.og ?? {})) {
    if (n >= SHARE_MAX_OG) break;
    if (typeof k !== "string" || typeof v !== "string" || !k || !v) continue;
    og[clipBytes(k, 40)] = clipBytes(v, 300);
    n++;
  }
  const jsonld = (facts.jsonld ?? [])
    .filter((x) => typeof x === "string" && x.trim())
    .slice(0, SHARE_MAX_JSONLD)
    .map((x) => clipBytes(x, SHARE_MAX_JSONLD_LEN));
  const wire: MediaPayload["candidates"] = [];
  for (const c of candidates) {
    if (wire.length >= SHARE_MAX_CANDIDATES) break;
    const w = wireCandidate(c);
    if (w) wire.push(w);
  }
  return {
    url: facts.url,
    title: clipBytes(facts.title ?? "", 256),
    og,
    jsonld,
    text: clipBytes((facts.text ?? "").replace(/\n{3,}/g, "\n\n"), SHARE_MAX_TEXT),
    shared_with_agents: agents === true,
    candidates: wire,
  };
}
