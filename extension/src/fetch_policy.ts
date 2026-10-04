/**
 * Fetch through this browser: the pure rules (docs/browser-integration.md,
 * section 14). Opal queues a request; the extension, not Opal, decides whether
 * it may run. Nothing in here touches `chrome.*`, so it runs under plain node
 * for the unit tests (tests/fetch_policy.test.mjs, `npm test`). Keep it free of
 * imports and of syntax node cannot strip.
 *
 * The rule the whole feature rests on: a page is fetched, with the user's real
 * cookies, only for an origin the USER put on the allow list (typed in the
 * options page, or approved in the side panel). Everything else fails closed.
 */

export const MAX_URL = 2048;
export const MAX_POST_BODY = 2048;
/** Text sent back to Opal. Matches Opal's own cap. */
export const MAX_RESULT = 2 * 1024 * 1024;
/** An allowed origin unused for this long drops off the list. */
export const ALLOW_TTL_MS = 30 * 24 * 60 * 60 * 1000;
/** How long the side panel waits for the user before the request is denied. */
export const ASK_TIMEOUT_MS = 80 * 1000;

export type FetchCode =
  | "origin_not_allowed"
  | "private_target"
  | "binary"
  | "network"
  | "timeout"
  | "redirected"
  | "bad_request"
  | "unsupported";

export interface Job {
  id: number;
  method: "GET" | "POST";
  url: string;
  body: string;
  /** May the user be asked about a new origin? False for the scraper fallback. */
  prompt: boolean;
}

export interface AllowEntry {
  /** scheme://host[:port], lower case. */
  origin: string;
  addedAt: number;
  lastUsed: number;
  /** Added for a private-network address (stored the same way, shown differently). */
  private: boolean;
}

// ── URLs and origins ────────────────────────────────────────────────────────

/** null when the URL is acceptable: http(s) only, no credentials, bounded, no
 *  control characters, spaces or backslashes. Same rules as Opal's side. */
export function badUrlReason(url: string): string | null {
  if (typeof url !== "string" || url.length === 0) return "empty";
  if (url.length > MAX_URL) return "too long";
  // eslint-disable-next-line no-control-regex
  if (/[\u0000- \u007f\\]/.test(url)) return "bad character";
  if (!/^https?:\/\//i.test(url)) return "scheme";
  const rest = url.replace(/^https?:\/\//i, "");
  const authority = rest.split(/[/?#]/, 1)[0] ?? "";
  if (authority === "" || authority.startsWith(":")) return "no host";
  if (authority.includes("@")) return "credentials";
  let u: URL;
  try {
    u = new URL(url);
  } catch {
    return "unparseable";
  }
  if (u.username || u.password) return "credentials";
  return null;
}

/** `scheme://host[:port]`, lower case, default ports dropped. null if not a URL. */
export function originOf(url: string): string | null {
  try {
    const u = new URL(url);
    if (u.protocol !== "http:" && u.protocol !== "https:") return null;
    return `${u.protocol}//${u.host}`.toLowerCase();
  } catch {
    return null;
  }
}

/** What a user types in the options page: a bare host, a host:port or a full
 *  URL. Returns the normalized origin or null. Paths and queries are dropped. */
export function normalizeOriginInput(input: string): string | null {
  const t = input.trim();
  if (!t || t.length > 300 || /[\s\\]/.test(t)) return null;
  const withScheme = /^[a-z][a-z0-9+.-]*:\/\//i.test(t) ? t : `https://${t}`;
  if (badUrlReason(withScheme) !== null) return null;
  return originOf(withScheme);
}

/** Host name without port or IPv6 brackets, lower case. */
export function hostOf(url: string): string {
  try {
    const h = new URL(url).hostname.toLowerCase();
    return h.startsWith("[") && h.endsWith("]") ? h.slice(1, -1) : h;
  } catch {
    return "";
  }
}

/** True only for something that looks like a public internet host name. Loopback,
 *  RFC 1918, link-local, `.local`, single-label names and every IP literal are
 *  private here and need the user's explicit say-so. Mirrors Opal's
 *  `browser_fetch_pure.publicHost`. A public-looking name that RESOLVES to a
 *  private address cannot be told apart from inside an extension. */
export function publicHost(hostIn: string): boolean {
  let h = hostIn.toLowerCase();
  if (h.endsWith(".")) h = h.slice(0, -1);
  if (h.length < 4 || h.length > 253) return false;
  if (!/^[a-z0-9.-]+$/.test(h)) return false;
  if (h === "localhost" || h.endsWith(".localhost")) return false;
  for (const suffix of [".local", ".internal", ".lan", ".home", ".intranet", ".corp", ".localdomain", ".arpa", ".test", ".invalid", ".example"]) {
    if (h.endsWith(suffix)) return false;
  }
  const labels = h.split(".");
  for (const label of labels) {
    if (label.length === 0 || label.length > 63) return false;
    if (label.startsWith("-") || label.endsWith("-")) return false;
    if (label.startsWith("0x")) return false;
  }
  if (labels.length < 2) return false;
  return /[a-z]/.test(labels[labels.length - 1] ?? "");
}

export function isPrivateTarget(url: string): boolean {
  return !publicHost(hostOf(url));
}

// ── The allow list ──────────────────────────────────────────────────────────

/** Entries that have not been used for `ALLOW_TTL_MS` are gone. */
export function liveEntries(list: AllowEntry[], now: number): AllowEntry[] {
  return list.filter((e) => e && typeof e.origin === "string" && now - (e.lastUsed || e.addedAt || 0) < ALLOW_TTL_MS);
}

export function isAllowed(list: AllowEntry[], origin: string, now: number): boolean {
  return liveEntries(list, now).some((e) => e.origin === origin);
}

export function addEntry(list: AllowEntry[], origin: string, now: number): AllowEntry[] {
  const rest = list.filter((e) => e.origin !== origin);
  return [...rest, { origin, addedAt: now, lastUsed: now, private: !publicHost(hostOf(origin)) }];
}

export function removeEntry(list: AllowEntry[], origin: string): AllowEntry[] {
  return list.filter((e) => e.origin !== origin);
}

export function touchEntry(list: AllowEntry[], origin: string, now: number): AllowEntry[] {
  return list.map((e) => (e.origin === origin ? { ...e, lastUsed: now } : e));
}

// ── The decision ────────────────────────────────────────────────────────────

export type Decision =
  | { kind: "allow"; origin: string }
  | { kind: "ask"; origin: string; private: boolean }
  | { kind: "deny"; code: FetchCode };

/** What to do with a job. Fail closed: only an origin on the list runs without
 *  asking, a private target is never run for an origin the user did not name,
 *  and a request that must not prompt (the scraper) is denied instead of asked. */
export function decide(job: Job, list: AllowEntry[], now: number): Decision {
  if (job.method !== "GET" && job.method !== "POST") return { kind: "deny", code: "unsupported" };
  if (badUrlReason(job.url) !== null) return { kind: "deny", code: "bad_request" };
  if (job.method === "GET" && job.body !== "") return { kind: "deny", code: "bad_request" };
  if (job.body.length > MAX_POST_BODY) return { kind: "deny", code: "bad_request" };
  const origin = originOf(job.url);
  if (!origin) return { kind: "deny", code: "bad_request" };
  const priv = isPrivateTarget(job.url);
  if (isAllowed(list, origin, now)) return { kind: "allow", origin };
  // A POST acts as the user on a site: never decided by a prompt an agent
  // could trigger, only by an origin already on the list.
  if (job.method === "POST") return { kind: "deny", code: "origin_not_allowed" };
  if (!job.prompt) return { kind: "deny", code: priv ? "private_target" : "origin_not_allowed" };
  return { kind: "ask", origin, private: priv };
}

/** After redirects: the final page may be read only if its origin is the one
 *  that was allowed, or is itself on the list. A redirect to a private address
 *  is never returned unless that address is on the list. */
export function finalAllowed(requestOrigin: string, finalUrl: string, list: AllowEntry[], now: number): boolean {
  const fo = originOf(finalUrl);
  if (!fo) return false;
  if (fo === requestOrigin) return true;
  return isAllowed(list, fo, now);
}

// ── Content ─────────────────────────────────────────────────────────────────

/** Text, JSON, HTML, XML in; images, video, archives, PDFs out. */
export function textContentType(ctIn: string): boolean {
  const base = (ctIn.split(";", 1)[0] ?? "").trim().toLowerCase();
  if (!base) return false;
  if (base.startsWith("text/")) return true;
  if (base === "application/json" || base === "application/xml" || base === "application/xhtml+xml" || base === "application/javascript") return true;
  return base.endsWith("+json") || base.endsWith("+xml");
}

/** Charset named in a Content-Type, or utf-8. Only labels TextDecoder knows. */
export function charsetOf(ct: string): string {
  const m = /charset\s*=\s*"?([A-Za-z0-9_.:-]+)"?/i.exec(ct);
  const label = (m?.[1] ?? "utf-8").toLowerCase();
  try {
    new TextDecoder(label);
    return label;
  } catch {
    return "utf-8";
  }
}

/** Cut `bytes` to `max` without ending inside a UTF-8 sequence. */
export function clipUtf8(bytes: Uint8Array, max: number): { bytes: Uint8Array; truncated: boolean } {
  if (bytes.length <= max) return { bytes, truncated: false };
  let n = max;
  while (n > 0 && ((bytes[n] ?? 0) & 0xc0) === 0x80) n -= 1;
  return { bytes: bytes.subarray(0, n), truncated: true };
}

// ── The answer ──────────────────────────────────────────────────────────────

/** Query string for `POST /api/browser/jobs/<id>`. The page text travels as the
 *  raw body. A final address that would not fit the head is shortened. */
export function resultQuery(r: { status: number; contentType: string; finalUrl: string; truncated: boolean }): string {
  let finalUrl = r.finalUrl;
  if (encodeURIComponent(finalUrl).length > 1500) {
    const o = originOf(finalUrl);
    finalUrl = o ? o + new URL(finalUrl).pathname : "";
    if (encodeURIComponent(finalUrl).length > 1500) finalUrl = "";
  }
  const ct = r.contentType.replace(/[\u0000-\u001f\u007f]/g, "").slice(0, 120);
  return (
    `ok=1&status=${r.status}&ctype=${encodeURIComponent(ct)}` +
    `&url=${encodeURIComponent(finalUrl)}&truncated=${r.truncated ? "1" : "0"}`
  );
}

export function failureQuery(code: FetchCode): string {
  return `ok=0&code=${code}`;
}
