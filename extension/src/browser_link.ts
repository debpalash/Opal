/**
 * Browser link (background side): pairing with Opal, and the media sniffer.
 *
 * Pairing: the user presses "Pair a browser" in Opal (Settings > Agent Access),
 * Opal shows a six digit code, and the user types it into this extension. The
 * extension POSTs it to /api/browser/pair and stores the token it gets back in
 * `chrome.storage.local` (never sync). That token is a separate credential from
 * the one the rest of the extension uses: it can only hand streams to Opal's
 * player (see src/services/access_pure.zig, `browser_routes`).
 *
 * Sniffer: with the optional `webRequest` permission granted, watch the tab's
 * own media requests (m3u8, mpd, mp4, webm, mp3, ts, plus extension-less ones
 * by Content-Type), remember them per tab with the Referer, Origin and
 * User-Agent the browser actually sent, and clear them when the tab navigates.
 * Nothing leaves the browser until the user presses Play or Queue.
 */

import {
  addOrigin,
  decidePending,
  ensureLoop,
  fetchEnabled,
  getAllow,
  listPending,
  removeOrigin,
  setFetchEnabled,
} from "./fetch_jobs";
import { jsonFetch, readLink, type BrowserResult, type StoredLink } from "./link_api";
import {
  SNIFFER_PERMISSIONS,
  addCandidate,
  buildMediaPayload,
  classifyContentType,
  classifyUrl,
  isNoiseUrl,
  makeCandidate,
  buildSharePayload,
  buildWantedPayload,
  sortCandidates,
  type Candidate,
  type PageFacts,
} from "./sniffer";

// ── Link state ──────────────────────────────────────────────────────────────

export type { BrowserResult } from "./link_api";

export interface LinkStatus {
  paired: boolean;
  label: string;
  sniffer: boolean;
}

function browserName(): string {
  const ua = navigator.userAgent;
  if (/Edg\//.test(ua)) return "edge";
  if (/Firefox\//.test(ua)) return "firefox";
  if (/Chrome\//.test(ua)) return "chrome";
  return "browser";
}

function defaultLabel(): string {
  const p = navigator.platform || "this computer";
  return `${browserName()} on ${p}`.slice(0, 60);
}

export async function pair(code: string, label: string): Promise<BrowserResult> {
  const clean = code.replace(/\s+/g, "");
  if (!/^\d{6}$/.test(clean)) return { ok: false, error: "The code is six digits." };
  const res = await jsonFetch(
    "/api/browser/pair",
    "POST",
    {
      code: clean,
      label: label.trim() || defaultLabel(),
      browser: browserName(),
      extension_id: chrome.runtime.id,
    },
    "",
  );
  if (!res.ok) return res;
  const d = res.data as { token?: string; id?: number } | undefined;
  if (!d?.token || typeof d.id !== "number") return { ok: false, error: "Opal sent an unexpected reply." };
  await chrome.storage.local.set({
    browserLink: { token: d.token, id: d.id, label: label.trim() || defaultLabel() } satisfies StoredLink,
  });
  ensureLoop();
  return { ok: true };
}

/** Unpair: tell Opal to forget this browser, then forget the token. The token
 *  is dropped locally even when Opal is unreachable, so "Unpair" always works. */
export async function unpair(): Promise<BrowserResult> {
  const link = await readLink();
  if (!link) return { ok: true };
  const res = await jsonFetch("/api/browser/revoke", "POST", undefined, link.token);
  await chrome.storage.local.remove("browserLink");
  return res.ok || res.status === 401 || res.status === 404
    ? { ok: true }
    : { ok: true, error: "Unpaired here, but Opal could not be reached: revoke it in Opal's Settings too." };
}

export async function linkStatus(): Promise<LinkStatus> {
  const link = await readLink();
  return { paired: !!link, label: link?.label ?? "", sniffer: await snifferGranted() };
}

/** Is this token still accepted? 401 means it was revoked in Opal. */
export async function verifyLink(): Promise<BrowserResult> {
  const link = await readLink();
  if (!link) return { ok: false, error: "Not paired." };
  const res = await jsonFetch("/api/browser/me", "GET", undefined, link.token);
  if (res.status === 401 || res.status === 403) {
    await chrome.storage.local.remove("browserLink");
    return { ok: false, status: res.status, error: "Opal no longer knows this browser: pair it again." };
  }
  return res;
}

// ── Per-tab candidates ──────────────────────────────────────────────────────

const SESSION_KEY = "sniffer.tabs";
const tabs = new Map<number, Candidate[]>();
const tabPage = new Map<number, string>();
let loaded = false;

function sessionArea(): chrome.storage.StorageArea | null {
  return (chrome.storage as unknown as { session?: chrome.storage.StorageArea }).session ?? null;
}

/** The worker is torn down after about 30 s idle; the list survives in session
 *  storage (memory only, cleared when the browser closes). */
async function ensureLoaded(): Promise<void> {
  if (loaded) return;
  loaded = true;
  const area = sessionArea();
  if (!area) return;
  try {
    const got = await area.get(SESSION_KEY);
    const saved = got[SESSION_KEY] as Record<string, Candidate[]> | undefined;
    for (const [k, v] of Object.entries(saved ?? {})) {
      if (!tabs.has(Number(k))) tabs.set(Number(k), v);
    }
  } catch {
    // session storage unavailable: keep going in memory
  }
}

function persist(): void {
  const area = sessionArea();
  if (!area) return;
  const out: Record<string, Candidate[]> = {};
  for (const [k, v] of tabs) out[String(k)] = v;
  area.set({ [SESSION_KEY]: out }).catch(() => {});
}

function updateBadge(tabId: number): void {
  const n = tabs.get(tabId)?.length ?? 0;
  try {
    chrome.action.setBadgeText({ tabId, text: n > 0 ? String(n) : "" });
    if (n > 0) chrome.action.setBadgeBackgroundColor({ tabId, color: "#2f8f5b" });
  } catch {
    // no action API: the panel still lists them
  }
}

function clearTab(tabId: number): void {
  if (tabs.delete(tabId)) persist();
  updateBadge(tabId);
}

async function record(
  tabId: number,
  url: string,
  kind: NonNullable<ReturnType<typeof classifyUrl>>,
  headers: Array<{ name: string; value?: string }> | undefined,
  frameUrl: string,
  size?: number,
): Promise<void> {
  await ensureLoaded();
  const c = makeCandidate({
    url,
    kind,
    headers,
    pageUrl: tabPage.get(tabId) ?? frameUrl,
    frameUrl,
    size,
  });
  const before = tabs.get(tabId) ?? [];
  const after = addCandidate(before, c);
  if (after === before) return;
  tabs.set(tabId, after);
  persist();
  updateBadge(tabId);
}

// ── webRequest wiring ───────────────────────────────────────────────────────

interface Pending {
  tabId: number;
  url: string;
  headers: Array<{ name: string; value?: string }> | undefined;
  frameUrl: string;
}
const pending = new Map<string, Pending>();
const MAX_PENDING = 128;
let registered = false;

// Observation is a consent decision: it runs only while the user has turned on
// "Detect media", i.e. granted the extension access to all sites. `webRequest`
// itself is a manifest permission (see snifferGranted for why), so the listeners
// exist whenever the worker runs; this flag is what keeps them inert until then.
// A worker woken by a request must wait for the answer, not guess "off" and drop
// the first events of every wake-up, hence a promise rather than a bare boolean.
let detectOn: Promise<boolean> = Promise.resolve(false);
function refreshDetect(): void {
  detectOn = snifferGranted();
}

type WR = typeof chrome.webRequest;

function frameOf(d: { documentUrl?: string; initiator?: string; url: string }): string {
  return d.documentUrl || d.initiator || "";
}

function onSendHeaders(d: chrome.webRequest.OnSendHeadersDetails): void {
  detectOn.then((on) => on && handleSendHeaders(d));
}

function handleSendHeaders(d: chrome.webRequest.OnSendHeadersDetails): void {
  if (d.tabId < 0) return;
  if (isNoiseUrl(d.url)) return;
  const kind = classifyUrl(d.url);
  if (kind) {
    void record(d.tabId, d.url, kind, d.requestHeaders, frameOf(d));
    return;
  }
  // No telling from the URL: keep the headers until the response says what it is.
  pending.set(d.requestId, { tabId: d.tabId, url: d.url, headers: d.requestHeaders, frameUrl: frameOf(d) });
  if (pending.size > MAX_PENDING) {
    const oldest = pending.keys().next().value;
    if (oldest !== undefined) pending.delete(oldest);
  }
}

function onHeadersReceived(d: chrome.webRequest.OnHeadersReceivedDetails): void {
  detectOn.then((on) => on && handleHeadersReceived(d));
}

function handleHeadersReceived(d: chrome.webRequest.OnHeadersReceivedDetails): void {
  const p = pending.get(d.requestId);
  if (!p) return;
  pending.delete(d.requestId);
  if (d.statusCode !== 200 && d.statusCode !== 206) return;
  const ct = d.responseHeaders?.find((h) => h.name.toLowerCase() === "content-type")?.value ?? "";
  const len = d.responseHeaders?.find((h) => h.name.toLowerCase() === "content-length")?.value;
  const kind = classifyContentType(ct);
  // A response under a few KB is a beacon or an error page, not a stream.
  const size = len ? Number(len) : undefined;
  if (!kind || (kind !== "hls" && kind !== "dash" && size !== undefined && size < 4096)) return;
  void record(p.tabId, p.url, kind, p.headers, p.frameUrl, size);
}

function onMainFrame(d: chrome.webRequest.OnBeforeRequestDetails): void {
  if (d.tabId < 0 || d.type !== "main_frame") return;
  // Cleared even while detection is off, so turning it on never shows a stale list.
  // A new page in this tab: the old page's streams are no longer relevant.
  tabPage.set(d.tabId, d.url);
  clearTab(d.tabId);
}

/** Attach the webRequest listeners. Safe to call repeatedly. */
export function registerSniffer(): void {
  if (registered) return;
  const wr = (chrome as unknown as { webRequest?: WR }).webRequest;
  if (!wr?.onSendHeaders) return;
  registered = true;
  wr.onBeforeRequest.addListener(
    (d) => {
      onMainFrame(d);
      return undefined;
    },
    { urls: ["http://*/*", "https://*/*"], types: ["main_frame"] },
  );
  const filter = { urls: ["http://*/*", "https://*/*"], types: ["media", "xmlhttprequest", "other"] } as chrome.webRequest.RequestFilter;
  try {
    // Referer, Origin and Cookie are only visible with extraHeaders (Chrome).
    wr.onSendHeaders.addListener(onSendHeaders, filter, ["requestHeaders", "extraHeaders"]);
  } catch {
    // Firefox has no extraHeaders and shows these headers anyway.
    wr.onSendHeaders.addListener(onSendHeaders, filter, ["requestHeaders"]);
  }
  wr.onHeadersReceived.addListener(
    (d) => {
      onHeadersReceived(d);
      return undefined;
    },
    filter,
    ["responseHeaders"],
  );
}

chrome.tabs.onRemoved.addListener((tabId) => {
  tabPage.delete(tabId);
  clearTab(tabId);
});

/**
 * "Detect media" is on when the extension has been given access to all sites,
 * which is the one consent the user is asked for, at the moment they turn it on.
 *
 * `webRequest` itself is declared in the manifest, not requested at runtime, and
 * that is a deviation from the design (docs/browser-integration.md, section 12):
 * measured on Chromium 152, an extension that obtains `webRequest` through
 * `chrome.permissions.request` gets the API object but no events until it is
 * restarted, while the same extension with the permission declared receives them
 * at once. `webRequest` carries no install warning on its own (the warning comes
 * from the host access), and with only loopback hosts granted by default it
 * observes nothing on real sites.
 */
export async function snifferGranted(): Promise<boolean> {
  try {
    return await (chrome.permissions.contains(SNIFFER_PERMISSIONS as chrome.permissions.Permissions) as unknown as Promise<boolean>);
  } catch {
    return false;
  }
}

refreshDetect();
try {
  chrome.permissions.onAdded.addListener(refreshDetect);
  chrome.permissions.onRemoved.addListener(refreshDetect);
} catch {
  // permissions events unavailable
}
registerSniffer();

// ── Panel-facing operations ─────────────────────────────────────────────────

export async function listCandidates(tabId: number): Promise<Candidate[]> {
  await ensureLoaded();
  return sortCandidates(tabs.get(tabId) ?? []);
}

export async function sendCandidate(
  tabId: number,
  id: string,
  action: "play" | "queue",
): Promise<BrowserResult> {
  await ensureLoaded();
  const link = await readLink();
  if (!link) return { ok: false, error: "Pair this browser with Opal first (extension Settings)." };
  const c = (tabs.get(tabId) ?? []).find((x) => x.id === id);
  if (!c) return { ok: false, error: "That stream is gone: the page moved on." };
  let title = "";
  let art = "";
  let pageUrl = c.pageUrl;
  try {
    const tab = await chrome.tabs.get(tabId);
    title = tab.title ?? "";
    pageUrl = tab.url || pageUrl;
  } catch {
    // the tab closed between the click and now
  }
  try {
    const [r] = await chrome.scripting.executeScript({
      target: { tabId },
      func: () =>
        document.querySelector<HTMLMetaElement>('meta[property="og:image"]')?.content ?? "",
    });
    if (typeof r?.result === "string") art = r.result;
  } catch {
    // not injectable (chrome:// page, no host permission): artwork is optional
  }
  const payload = buildMediaPayload(c, action, { url: pageUrl, title, art });
  if (!payload) return { ok: false, error: "That URL cannot be sent to Opal." };
  const res = await jsonFetch("/api/browser/media", "POST", payload, link.token);
  if (res.status === 401) {
    await chrome.storage.local.remove("browserLink");
    return { ...res, error: "Opal no longer knows this browser: pair it again." };
  }
  return res;
}

/** "Add to Wanted": the title is whatever the user typed in the panel, and one
 *  click is one request. Opal parses it and adds it to the Wanted list. */
export async function addToWanted(title: string, tabId: number): Promise<BrowserResult & { result?: string; kind?: string; wantedTitle?: string }> {
  const link = await readLink();
  if (!link) return { ok: false, error: "Pair this browser with Opal first (extension Settings)." };
  let pageUrl = "";
  try {
    pageUrl = (await chrome.tabs.get(tabId)).url ?? "";
  } catch {
    // the tab closed: the title is what matters
  }
  const payload = buildWantedPayload(title, pageUrl);
  if (!payload) return { ok: false, error: "Type a title first, for example Dune 2021 or Severance S02E03." };
  const res = await jsonFetch("/api/browser/media", "POST", payload, link.token);
  if (res.status === 401) {
    await chrome.storage.local.remove("browserLink");
    return { ...res, error: "Opal no longer knows this browser: pair it again." };
  }
  const d = res.data as { result?: string; kind?: string; title?: string } | undefined;
  return { ...res, result: d?.result, kind: d?.kind, wantedTitle: d?.title };
}

// ── Sharing the page with Opal ──────────────────────────────────────────────

/** Read what the page itself says about itself, in the tab, when the user asks.
 *  Needs access to the page (activeTab after the user's click, or all-sites
 *  access); without it only the tab's own title and address are shared. */
async function readPageFacts(tabId: number): Promise<{ facts: PageFacts; read: boolean } | null> {
  let tab: chrome.tabs.Tab;
  try {
    tab = await chrome.tabs.get(tabId);
  } catch {
    return null;
  }
  const facts: PageFacts = { url: tab.url ?? "", title: tab.title ?? "", og: {}, jsonld: [], text: "" };
  let read = false;
  try {
    const [r] = await chrome.scripting.executeScript({
      target: { tabId },
      func: () => {
        const og: Record<string, string> = {};
        for (const m of Array.from(document.querySelectorAll<HTMLMetaElement>('meta[property^="og:"], meta[name^="twitter:"]'))) {
          const k = m.getAttribute("property") || m.getAttribute("name") || "";
          if (k && m.content && !(k in og)) og[k] = m.content;
          if (Object.keys(og).length >= 12) break;
        }
        const jsonld: string[] = [];
        for (const sc of Array.from(document.querySelectorAll('script[type="application/ld+json"]'))) {
          if (sc.textContent) jsonld.push(sc.textContent.slice(0, 4000));
          if (jsonld.length >= 3) break;
        }
        return { title: document.title, og, jsonld, text: (document.body?.innerText ?? "").slice(0, 20000) };
      },
    });
    const v = r?.result as { title?: string; og?: Record<string, string>; jsonld?: string[]; text?: string } | undefined;
    if (v) {
      facts.title = v.title || facts.title;
      facts.og = v.og ?? {};
      facts.jsonld = v.jsonld ?? [];
      facts.text = v.text ?? "";
      read = true;
    }
  } catch {
    // not injectable (a browser page, or no access to this site): share title and address only
  }
  return { facts, read };
}

export interface ShareResult extends BrowserResult {
  /** The page text and metadata were read; false when only title and address went. */
  pageRead?: boolean;
  streams?: number;
}

/** "Share this page with Opal": one page, one user click, nothing in the
 *  background. `agents` is the box the user ticked for this page and defaults to
 *  false; Opal also has its own switch, which this extension cannot see or change. */
export async function sharePage(tabId: number, agents: boolean): Promise<ShareResult> {
  await ensureLoaded();
  const link = await readLink();
  if (!link) return { ok: false, error: "Pair this browser with Opal first (extension Settings)." };
  const got = await readPageFacts(tabId);
  if (!got) return { ok: false, error: "That tab is gone." };
  const streams = sortCandidates(tabs.get(tabId) ?? []);
  const payload = buildSharePayload(got.facts, streams, agents === true);
  if (!payload) return { ok: false, error: "This page's address cannot be shared (only http and https pages)." };
  const res = await jsonFetch("/api/browser/page", "POST", payload, link.token);
  if (res.status === 401) {
    await chrome.storage.local.remove("browserLink");
    return { ...res, error: "Opal no longer knows this browser: pair it again." };
  }
  return { ...res, pageRead: got.read, streams: payload.candidates.length };
}

// ── Link heartbeat ──────────────────────────────────────────────────────────

// Opal calls a browser "connected" when it was seen in the last couple of
// minutes, and there is no open socket yet, so the worker checks in once a
// minute while paired. The call is the same token check the panel uses.
try {
  chrome.alarms?.create("opal-link", { periodInMinutes: 1 });
  chrome.alarms?.onAlarm.addListener((a) => {
    if (a.name === "opal-link") {
      void readLink().then((l) => l && jsonFetch("/api/browser/me", "GET", undefined, l.token));
      // A worker that was shut down is not polling for fetch jobs: start again.
      ensureLoop();
    }
  });
} catch {
  // no alarms API: the panel's own checks still count
}

// ── Message entry point ─────────────────────────────────────────────────────

export interface BrowserMessage {
  kind: "browser";
  op:
    | "status"
    | "pair"
    | "unpair"
    | "verify"
    | "list"
    | "send"
    | "enable"
    | "share"
    | "wanted"
    | "fetch-state"
    | "fetch-decide"
    | "fetch-add"
    | "fetch-remove"
    | "fetch-enable";
  code?: string;
  label?: string;
  tabId?: number;
  id?: string;
  action?: "play" | "queue";
  agents?: boolean;
  title?: string;
  /** fetch-decide: the pending request; fetch-add / fetch-remove: the site. */
  jobId?: number;
  decision?: "once" | "always" | "deny";
  origin?: string;
  on?: boolean;
}

export async function handleBrowserMessage(msg: BrowserMessage): Promise<unknown> {
  switch (msg.op) {
    case "status":
      return linkStatus();
    case "pair":
      return pair(msg.code ?? "", msg.label ?? "");
    case "unpair":
      return unpair();
    case "verify":
      return verifyLink();
    case "enable":
      refreshDetect();
      return { ok: await snifferGranted() };
    case "list":
      return { ok: true, candidates: await listCandidates(msg.tabId ?? -1) };
    case "send":
      return sendCandidate(msg.tabId ?? -1, msg.id ?? "", msg.action === "queue" ? "queue" : "play");
    case "share":
      return sharePage(msg.tabId ?? -1, msg.agents === true);
    case "wanted":
      return addToWanted(msg.title ?? "", msg.tabId ?? -1);
    case "fetch-state":
      return { ok: true, enabled: await fetchEnabled(), allow: await getAllow(), pending: await listPending() };
    case "fetch-decide":
      return decidePending(msg.jobId ?? -1, msg.decision === "once" || msg.decision === "always" ? msg.decision : "deny");
    case "fetch-add":
      return addOrigin(msg.origin ?? "");
    case "fetch-remove":
      await removeOrigin(msg.origin ?? "");
      return { ok: true };
    case "fetch-enable":
      await setFetchEnabled(msg.on !== false);
      return { ok: true };
    default:
      return { ok: false, error: "unknown operation" };
  }
}

// Poll for fetch jobs whenever this worker is up and the browser is paired.
ensureLoop();
