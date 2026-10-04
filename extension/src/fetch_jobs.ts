/**
 * Fetch through this browser (background side).
 *
 * Opal queues a request for a page; this worker long-polls `GET /api/browser/jobs`,
 * and for each job decides (fetch_policy.ts) whether it may run. It runs only
 * for an origin on the user's allow list; a new origin is shown in the side
 * panel and the user chooses Allow once, Always or Deny. The request then runs
 * with the user's real cookies (`credentials: "include"`), the text is cut at
 * 2 MB, binary is refused, and the answer goes back to
 * `POST /api/browser/jobs/<id>` (metadata in the query, page text as the body).
 *
 * Who can change the allow list: the user, in this extension (options page and
 * side panel). Nothing from Opal can add to it, and the page text is never
 * given to anything but Opal.
 */

import { jsonFetch, readLink, type StoredLink } from "./link_api";
import {
  ASK_TIMEOUT_MS,
  MAX_RESULT,
  addEntry,
  charsetOf,
  clipUtf8,
  decide,
  failureQuery,
  finalAllowed,
  liveEntries,
  normalizeOriginInput,
  removeEntry,
  resultQuery,
  textContentType,
  touchEntry,
  type AllowEntry,
  type FetchCode,
  type Job,
} from "./fetch_policy";

const ALLOW_KEY = "fetchAllow";
const ENABLED_KEY = "fetchEnabled";
const PENDING_KEY = "fetchPending";
const POLL_WAIT_S = 20;

// ── Storage ─────────────────────────────────────────────────────────────────

export async function getAllow(): Promise<AllowEntry[]> {
  const got = await chrome.storage.local.get(ALLOW_KEY);
  const raw = got[ALLOW_KEY];
  const list = Array.isArray(raw) ? (raw as AllowEntry[]) : [];
  const live = liveEntries(list, Date.now());
  if (live.length !== list.length) await chrome.storage.local.set({ [ALLOW_KEY]: live });
  return live;
}

async function setAllow(list: AllowEntry[]): Promise<void> {
  await chrome.storage.local.set({ [ALLOW_KEY]: list });
}

/** On unless the user turned it off. Off means no polling at all, so Opal sees no browser. */
export async function fetchEnabled(): Promise<boolean> {
  const got = await chrome.storage.local.get(ENABLED_KEY);
  return got[ENABLED_KEY] !== false;
}

export async function setFetchEnabled(on: boolean): Promise<void> {
  await chrome.storage.local.set({ [ENABLED_KEY]: on });
  if (on) ensureLoop();
}

export interface Pending {
  job: Job;
  origin: string;
  private: boolean;
  deadline: number;
}

const memoryPending = new Map<number, Pending>();

function sessionArea(): chrome.storage.StorageArea | null {
  return (chrome.storage as unknown as { session?: chrome.storage.StorageArea }).session ?? null;
}

async function readPending(): Promise<Pending[]> {
  const area = sessionArea();
  let list: Pending[] = [];
  if (area) {
    try {
      const got = await area.get(PENDING_KEY);
      if (Array.isArray(got[PENDING_KEY])) list = got[PENDING_KEY] as Pending[];
    } catch {
      list = [...memoryPending.values()];
    }
  } else list = [...memoryPending.values()];
  const now = Date.now();
  return list.filter((p) => p && p.deadline > now);
}

async function writePending(list: Pending[]): Promise<void> {
  memoryPending.clear();
  for (const p of list) memoryPending.set(p.job.id, p);
  const area = sessionArea();
  if (area) await area.set({ [PENDING_KEY]: list }).catch(() => {});
  try {
    chrome.action.setBadgeText({ text: list.length ? "?" : "" });
    if (list.length) chrome.action.setBadgeBackgroundColor({ color: "#c77d12" });
  } catch {
    // no action API: the panel still lists them
  }
}

export async function listPending(): Promise<Pending[]> {
  const list = await readPending();
  return list;
}

// ── Answers ─────────────────────────────────────────────────────────────────

async function answer(link: StoredLink, id: number, query: string, body?: Uint8Array): Promise<void> {
  const res = await jsonFetch(`/api/browser/jobs/${id}?${query}`, "POST", body ?? "", link.token, {
    rawText: true,
    timeoutMs: 30000,
  });
  if (res.status === 401) await chrome.storage.local.remove("browserLink");
}

async function answerFail(id: number, code: FetchCode): Promise<void> {
  const link = await readLink();
  if (link) await answer(link, id, failureQuery(code));
}

async function readCapped(res: Response, cap: number): Promise<{ bytes: Uint8Array; overflow: boolean }> {
  if (!res.body) return { bytes: new Uint8Array(0), overflow: false };
  const reader = res.body.getReader();
  const chunks: Uint8Array[] = [];
  let total = 0;
  let overflow = false;
  for (;;) {
    const { done, value } = await reader.read();
    if (done) break;
    if (!value) continue;
    if (total + value.length > cap) {
      chunks.push(value.subarray(0, cap - total));
      total = cap;
      overflow = true;
      await reader.cancel().catch(() => {});
      break;
    }
    chunks.push(value);
    total += value.length;
  }
  const bytes = new Uint8Array(total);
  let off = 0;
  for (const c of chunks) {
    bytes.set(c, off);
    off += c.length;
  }
  return { bytes, overflow };
}

/** Run an allowed job and send the text back. */
async function runFetch(job: Job, origin: string): Promise<void> {
  const link = await readLink();
  if (!link) return;
  let res: Response;
  try {
    res = await fetch(job.url, {
      method: job.method,
      credentials: "include",
      redirect: "follow",
      cache: "no-store",
      referrerPolicy: "no-referrer",
      headers: job.method === "POST" ? { "Content-Type": "application/x-www-form-urlencoded" } : undefined,
      body: job.method === "POST" ? job.body : undefined,
      signal: AbortSignal.timeout(30000),
    });
  } catch (e) {
    return answer(link, job.id, failureQuery((e as Error)?.name === "TimeoutError" ? "timeout" : "network"));
  }
  const list = await getAllow();
  // A redirect may only land on an origin the user also allowed: the page is
  // not read otherwise (the request itself has already happened).
  if (!finalAllowed(origin, res.url || job.url, list, Date.now())) {
    void res.body?.cancel().catch(() => {});
    return answer(link, job.id, failureQuery("redirected"));
  }
  const ct = res.headers.get("content-type") ?? "";
  if (!textContentType(ct)) {
    void res.body?.cancel().catch(() => {});
    return answer(link, job.id, failureQuery("binary"));
  }
  let raw: { bytes: Uint8Array; overflow: boolean };
  try {
    raw = await readCapped(res, MAX_RESULT);
  } catch {
    return answer(link, job.id, failureQuery("network"));
  }
  if (raw.bytes.subarray(0, 4096).includes(0)) return answer(link, job.id, failureQuery("binary"));
  let bytes = raw.bytes;
  const charset = charsetOf(ct);
  if (charset !== "utf-8") {
    bytes = new TextEncoder().encode(new TextDecoder(charset).decode(raw.bytes));
  }
  const clipped = clipUtf8(bytes, MAX_RESULT);
  await setAllow(touchEntry(list, origin, Date.now()));
  await answer(
    link,
    job.id,
    resultQuery({ status: res.status, contentType: ct, finalUrl: res.url || job.url, truncated: raw.overflow || clipped.truncated }),
    clipped.bytes,
  );
}

// ── Jobs ────────────────────────────────────────────────────────────────────

function parseJob(raw: unknown): Job | null {
  const j = raw as Partial<Job> | null;
  if (!j || typeof j !== "object") return null;
  if (typeof j.id !== "number" || !Number.isInteger(j.id) || j.id <= 0) return null;
  if (typeof j.url !== "string") return null;
  return {
    id: j.id,
    method: j.method === "POST" ? "POST" : "GET",
    url: j.url,
    body: typeof j.body === "string" ? j.body : "",
    prompt: j.prompt === true,
  };
}

function notifyAsk(origin: string, isPrivate: boolean): void {
  try {
    chrome.notifications.create({
      type: "basic",
      iconUrl: chrome.runtime.getURL("images/icon-128.png"),
      title: isPrivate ? "Opal wants to fetch from your private network" : "Opal wants to fetch a page",
      message: `${origin} through this browser. Open the Opal panel to allow or deny.`,
    });
  } catch {
    // notifications unavailable: the badge and the panel still show it
  }
}

async function handleJob(raw: unknown): Promise<void> {
  const job = parseJob(raw);
  if (!job) return;
  const list = await getAllow();
  const d = decide(job, list, Date.now());
  if (d.kind === "deny") return answerFail(job.id, d.code);
  if (d.kind === "allow") return runFetch(job, d.origin);
  // Ask: the side panel shows the origin and the user decides. The decision
  // arrives as a message, so a worker restart in between loses nothing.
  const pending = await readPending();
  if (pending.some((p) => p.job.id === job.id)) return;
  pending.push({ job, origin: d.origin, private: d.private, deadline: Date.now() + ASK_TIMEOUT_MS });
  await writePending(pending);
  notifyAsk(d.origin, d.private);
  setTimeout(() => void expirePending(job.id), ASK_TIMEOUT_MS + 500);
}

async function expirePending(id: number): Promise<void> {
  const all = [...(await rawPending())];
  const still = all.find((p) => p.job.id === id);
  if (!still) return;
  await writePending(all.filter((p) => p.job.id !== id));
  await answerFail(id, "origin_not_allowed");
}

async function rawPending(): Promise<Pending[]> {
  const area = sessionArea();
  if (!area) return [...memoryPending.values()];
  try {
    const got = await area.get(PENDING_KEY);
    return Array.isArray(got[PENDING_KEY]) ? (got[PENDING_KEY] as Pending[]) : [];
  } catch {
    return [...memoryPending.values()];
  }
}

/** The user's answer from the side panel. Deny, and anything unexpected, fails closed. */
export async function decidePending(id: number, decision: "once" | "always" | "deny"): Promise<{ ok: boolean; error?: string }> {
  const all = await rawPending();
  const p = all.find((x) => x.job.id === id);
  if (!p) return { ok: false, error: "That request is gone (it timed out)." };
  await writePending(all.filter((x) => x.job.id !== id));
  if (decision !== "once" && decision !== "always") {
    await answerFail(id, "origin_not_allowed");
    return { ok: true };
  }
  if (p.deadline <= Date.now()) return { ok: false, error: "That request timed out." };
  if (decision === "always") await setAllow(addEntry(await getAllow(), p.origin, Date.now()));
  void runFetch(p.job, p.origin);
  return { ok: true };
}

// ── The allow list, edited by the user ──────────────────────────────────────

export async function addOrigin(input: string): Promise<{ ok: boolean; error?: string; origin?: string }> {
  const origin = normalizeOriginInput(input);
  if (!origin) return { ok: false, error: "That is not a web address (use a site like example.org or http://nas.local:8096)." };
  await setAllow(addEntry(await getAllow(), origin, Date.now()));
  return { ok: true, origin };
}

export async function removeOrigin(origin: string): Promise<void> {
  await setAllow(removeEntry(await getAllow(), origin));
}

// ── The poll loop ───────────────────────────────────────────────────────────

let looping = false;

function sleep(ms: number): Promise<void> {
  return new Promise((r) => setTimeout(r, ms));
}

/** Start polling if paired and enabled. Safe to call repeatedly; the alarm and
 *  every worker start call it, since a worker that was shut down stops polling. */
export function ensureLoop(): void {
  if (looping) return;
  looping = true;
  void loop().finally(() => {
    looping = false;
  });
}

async function loop(): Promise<void> {
  let backoff = 2000;
  for (;;) {
    if (!(await fetchEnabled())) return;
    const link = await readLink();
    if (!link) return;
    const res = await jsonFetch(`/api/browser/jobs?wait=${POLL_WAIT_S}`, "GET", undefined, link.token, { timeoutMs: 30000 });
    if (res.status === 401) {
      await chrome.storage.local.remove("browserLink");
      return;
    }
    if (!res.ok) {
      await sleep(backoff);
      backoff = Math.min(backoff * 2, 30000);
      continue;
    }
    backoff = 2000;
    const job = (res.data as { job?: unknown } | undefined)?.job;
    if (job) void handleJob(job);
  }
}
