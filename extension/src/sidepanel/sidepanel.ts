/**
 * Opal side panel — the persistent primary surface (Chrome sidePanel / Firefox
 * sidebar_action, one HTML file for both). Hosts:
 *   • connection status
 *   • "Add this site as an Opal source" (when a manga/novel framework is detected)
 *   • typed send of the current tab (play / queue / download / read)
 *   • a now-playing mini-remote polling /api/status (play-pause, seek, volume,
 *     next audio/sub)
 *   • a compact recent-actions log
 *
 * All Opal traffic is delegated to the background worker via messages.
 */

import type {
  Detection,
  OpalFile,
  OpalQueueItem,
  OpalRequest,
  OpalResponse,
  OpalSearchResult,
  OpalStatus,
  OpalTorrent,
  OpalUnifiedResults,
} from "../shared";

const $ = <T extends HTMLElement>(id: string) => document.getElementById(id) as T;

const statusText = $<HTMLSpanElement>("status-text");
const statusDot = $<HTMLSpanElement>("status-dot");
const sourceCard = $<HTMLElement>("source-card");
const sourceSite = $<HTMLElement>("source-site");
const sourceFw = $<HTMLElement>("source-fw");
const addSourceBtn = $<HTMLButtonElement>("add-source");
const tabType = $<HTMLElement>("tab-type");
const tabTitle = $<HTMLElement>("tab-title");
const sendBtn = $<HTMLButtonElement>("send");
const queueBtn = $<HTMLButtonElement>("queue");
const downloadBtn = $<HTMLButtonElement>("download");
const readBtn = $<HTMLButtonElement>("read");
const npTitle = $<HTMLElement>("np-title");
const seek = $<HTMLInputElement>("seek");
const npPos = $<HTMLElement>("np-pos");
const npDur = $<HTMLElement>("np-dur");
const playpauseBtn = $<HTMLButtonElement>("playpause");
const backBtn = $<HTMLButtonElement>("back");
const fwdBtn = $<HTMLButtonElement>("fwd");
const nextAudioBtn = $<HTMLButtonElement>("next-audio");
const nextSubBtn = $<HTMLButtonElement>("next-sub");
const muteBtn = $<HTMLButtonElement>("mute");
const fullscreenBtn = $<HTMLButtonElement>("fullscreen");
const vol = $<HTMLInputElement>("vol");
const searchQ = $<HTMLInputElement>("search-q");
const searchGo = $<HTMLButtonElement>("search-go");
const searchResults = $<HTMLUListElement>("search-results");
const queueList = $<HTMLUListElement>("queue-list");
const queueRefresh = $<HTMLButtonElement>("queue-refresh");
const castFind = $<HTMLButtonElement>("cast-find");
const castStopBtn = $<HTMLButtonElement>("cast-stop");
const castListEl = $<HTMLUListElement>("cast-list");
const partyHostBtn = $<HTMLButtonElement>("party-host");
const partyIp = $<HTMLInputElement>("party-ip");
const partyJoinBtn = $<HTMLButtonElement>("party-join");
const partyLeaveBtn = $<HTMLButtonElement>("party-leave");
const partyStatusEl = $<HTMLElement>("party-status");
const torrentsCard = $<HTMLElement>("torrents-card");
const torrentsList = $<HTMLUListElement>("torrents-list");
const torrentsRefresh = $<HTMLButtonElement>("torrents-refresh");
const downloadsList = $<HTMLUListElement>("downloads-list");
const downloadsRefresh = $<HTMLButtonElement>("downloads-refresh");
const downloadsUp = $<HTMLButtonElement>("downloads-up");
const historyList = $<HTMLUListElement>("history-list");
const historyRefresh = $<HTMLButtonElement>("history-refresh");
const setupCard = $<HTMLElement>("setup-card");
const setupOpen = $<HTMLButtonElement>("setup-open");
const recent = $<HTMLUListElement>("recent");
const optionsLink = $<HTMLAnchorElement>("options");

let detection: Detection | null = null;
let seeking = false;
let volDragging = false;

function send(req: OpalRequest): Promise<OpalResponse> {
  return chrome.runtime.sendMessage(req) as Promise<OpalResponse>;
}

function logRecent(text: string, ok: boolean): void {
  const empty = recent.querySelector(".recent-empty");
  if (empty) empty.remove();
  const li = document.createElement("li");
  li.className = ok ? "ok" : "err";
  const t = new Date().toLocaleTimeString([], { hour: "2-digit", minute: "2-digit" });
  li.innerHTML = `<span class="rt">${t}</span> ${text}`;
  recent.prepend(li);
  while (recent.children.length > 8) recent.lastChild?.remove();
}

async function act(label: string, req: OpalRequest): Promise<void> {
  const res = await send(req);
  logRecent(res.ok ? `${label}` : `${label} failed`, res.ok);
}

function fmt(sec: number): string {
  if (!isFinite(sec) || sec <= 0) return "0:00";
  const s = Math.floor(sec % 60);
  const m = Math.floor(sec / 60) % 60;
  const h = Math.floor(sec / 3600);
  const mm = h > 0 ? String(m).padStart(2, "0") : String(m);
  const ss = String(s).padStart(2, "0");
  return h > 0 ? `${h}:${mm}:${ss}` : `${mm}:${ss}`;
}

// ── Current-tab detection ────────────────────────────────────────────────────

async function loadDetection(): Promise<void> {
  const [tab] = await chrome.tabs.query({ active: true, currentWindow: true });
  detection = null;
  if (tab?.id) {
    try {
      detection = (await chrome.tabs.sendMessage(tab.id, { kind: "detect" })) as Detection;
    } catch {
      detection = null;
    }
  }
  renderDetection(tab?.url ?? "");
}

const FRAMEWORK_LABEL: Record<string, string> = {
  madara: "Madara (manga)",
  mangathemesia: "MangaThemesia (manga)",
  heancms: "HeanCMS (manhwa)",
  madara_novel: "Madara (novel)",
  lightnovelwp: "LightNovel WP",
  readwn: "ReadWN novel",
};

function renderDetection(fallbackUrl: string): void {
  if (detection?.framework) {
    sourceCard.hidden = false;
    sourceSite.textContent = detection.siteName;
    sourceFw.textContent = FRAMEWORK_LABEL[detection.framework] ?? detection.framework;
  } else {
    sourceCard.hidden = true;
  }
  const pt = detection?.pageType ?? "page";
  tabType.textContent = pt.charAt(0).toUpperCase() + pt.slice(1);
  tabTitle.textContent = detection?.title || fallbackUrl || "—";
}

// ── Send actions ─────────────────────────────────────────────────────────────

function currentUrl(): string {
  return detection?.url ?? "";
}

sendBtn.addEventListener("click", async () => {
  const url = currentUrl();
  if (!url) return;
  await act("Sent to Opal", {
    kind: "opal",
    action: "ingest",
    ingestType: detection?.pageType ?? "media",
    url,
    title: detection?.title,
    art: detection?.art,
    subtitle: detection?.subtitle,
  });
});

queueBtn.addEventListener("click", async () => {
  const url = currentUrl();
  if (!url) return;
  await act("Queued", {
    kind: "opal",
    action: "ingest",
    ingestType: "queue",
    url,
    title: detection?.title,
    art: detection?.art,
    subtitle: detection?.subtitle,
  });
});

downloadBtn.addEventListener("click", async () => {
  const url = currentUrl();
  if (!url) return;
  await act("Download started", { kind: "opal", action: "download", url });
});

readBtn.addEventListener("click", async () => {
  const url = currentUrl();
  if (!url) return;
  await act("Sent to reader", { kind: "opal", action: "ingest", ingestType: "article", url, title: detection?.title });
});

addSourceBtn.addEventListener("click", async () => {
  if (!detection?.framework) return;
  addSourceBtn.disabled = true;
  addSourceBtn.textContent = "Adding…";
  const res = await send({
    kind: "opal",
    action: "addSource",
    framework: detection.framework,
    base: detection.origin,
  });
  addSourceBtn.disabled = false;
  addSourceBtn.textContent = res.ok ? "Added ✓" : "Add as Opal source";
  logRecent(res.ok ? `Added ${detection.siteName} as source` : `Add source failed`, res.ok);
});

// ── Remote transport ─────────────────────────────────────────────────────────

playpauseBtn.addEventListener("click", () => send({ kind: "opal", action: "playpause" }));
backBtn.addEventListener("click", () => send({ kind: "opal", action: "seekBack" }));
fwdBtn.addEventListener("click", () => send({ kind: "opal", action: "seekFwd" }));
nextAudioBtn.addEventListener("click", () => send({ kind: "opal", action: "nextAudio" }));
nextSubBtn.addEventListener("click", () => send({ kind: "opal", action: "nextSub" }));
muteBtn.addEventListener("click", () => send({ kind: "opal", action: "mute" }));
fullscreenBtn.addEventListener("click", () => send({ kind: "opal", action: "fullscreen" }));

seek.addEventListener("input", () => (seeking = true));
seek.addEventListener("change", async () => {
  await send({ kind: "opal", action: "seek", value: Number(seek.value) });
  seeking = false;
});
vol.addEventListener("input", () => (volDragging = true));
vol.addEventListener("change", async () => {
  await send({ kind: "opal", action: "volume", value: Number(vol.value) });
  volDragging = false;
});

// ── Search every source ───────────────────────────────────────────────────────

function playable(r: OpalSearchResult): string | null {
  if (r.action === "magnet") return r.data;
  if (r.action === "yt_play") return `https://www.youtube.com/watch?v=${r.data}`;
  return null; // tmdb/anime/jellyfin ids need in-app navigation
}

function renderResults(list: HTMLUListElement, results: OpalSearchResult[]): void {
  list.textContent = "";
  if (!results.length) {
    const li = document.createElement("li");
    li.className = "results-empty";
    li.textContent = "No results.";
    list.append(li);
    return;
  }
  for (const r of results.slice(0, 40)) {
    const url = playable(r);
    const li = document.createElement("li");
    li.className = "result";
    const meta = document.createElement("div");
    meta.className = "result-meta";
    meta.innerHTML = `<span class="badge">${r.source}</span><span class="result-title">${escapeHtml(r.title)}</span><span class="result-detail">${escapeHtml(r.detail)}</span>`;
    li.append(meta);
    if (url) {
      const btns = document.createElement("div");
      btns.className = "result-btns";
      const play = document.createElement("button");
      play.className = "mini-btn primary";
      play.textContent = "▶";
      play.title = "Play in Opal";
      play.addEventListener("click", () => act("Playing", { kind: "opal", action: "open", url }));
      const q = document.createElement("button");
      q.className = "mini-btn";
      q.textContent = "＋";
      q.title = "Queue in Opal";
      q.addEventListener("click", () => act("Queued", { kind: "opal", action: "ingest", ingestType: "queue", url }));
      btns.append(play, q);
      li.append(btns);
    }
    list.append(li);
  }
}

function escapeHtml(s: string): string {
  return s.replace(/[&<>"']/g, (c) => ({ "&": "&amp;", "<": "&lt;", ">": "&gt;", '"': "&quot;", "'": "&#39;" })[c] as string);
}

async function runSearch(): Promise<void> {
  const q = searchQ.value.trim();
  if (!q) return;
  searchGo.disabled = true;
  searchResults.textContent = "";
  const li = document.createElement("li");
  li.className = "results-empty";
  li.textContent = "Searching…";
  searchResults.append(li);
  const res = await send({ kind: "opal", action: "unifiedSearch", query: q });
  searchGo.disabled = false;
  if (!res.ok) {
    renderResults(searchResults, []);
    logRecent("Search failed", false);
    return;
  }
  const data = res.data as OpalUnifiedResults | undefined;
  renderResults(searchResults, data?.results ?? []);
}

searchGo.addEventListener("click", runSearch);
searchQ.addEventListener("keydown", (e) => {
  if (e.key === "Enter") runSearch();
});

// ── Play queue ─────────────────────────────────────────────────────────────────

async function loadQueue(): Promise<void> {
  const res = await send({ kind: "opal", action: "queueList" });
  queueList.textContent = "";
  const items = res.ok ? ((res.data as { items?: OpalQueueItem[] })?.items ?? []) : [];
  if (!items.length) {
    const li = document.createElement("li");
    li.className = "results-empty";
    li.textContent = res.ok ? "Queue is empty." : "Opal not reachable.";
    queueList.append(li);
    return;
  }
  items.forEach((item, i) => {
    const li = document.createElement("li");
    li.className = "result";
    const label = item.url.split("/").pop() || item.url;
    const meta = document.createElement("div");
    meta.className = "result-meta";
    meta.innerHTML = `<span class="result-title${item.played ? " played" : ""}">${escapeHtml(label)}</span>`;
    li.append(meta);
    const btns = document.createElement("div");
    btns.className = "result-btns";
    const up = document.createElement("button");
    up.className = "mini-btn";
    up.textContent = "↑";
    up.disabled = i === 0;
    up.addEventListener("click", async () => {
      await send({ kind: "opal", action: "queueMove", idx: i, moveDir: "up" });
      loadQueue();
    });
    const down = document.createElement("button");
    down.className = "mini-btn";
    down.textContent = "↓";
    down.disabled = i === items.length - 1;
    down.addEventListener("click", async () => {
      await send({ kind: "opal", action: "queueMove", idx: i, moveDir: "down" });
      loadQueue();
    });
    btns.append(up, down);
    li.append(btns);
    queueList.append(li);
  });
}

queueRefresh.addEventListener("click", loadQueue);

// ── Torrents in flight ───────────────────────────────────────────────────────
//
// The panel could start a torrent and then say nothing about it. This polls
// only while there is something to show: the card hides itself when the list is
// empty, so an Opal with no torrents costs one request per panel open.

function fmtRate(bytesPerSec: number): string {
  if (!isFinite(bytesPerSec) || bytesPerSec <= 0) return "0 KB/s";
  if (bytesPerSec >= 1024 * 1024) return `${(bytesPerSec / (1024 * 1024)).toFixed(1)} MB/s`;
  return `${Math.round(bytesPerSec / 1024)} KB/s`;
}

function fmtSize(bytes: number): string {
  if (!isFinite(bytes) || bytes <= 0) return "";
  const units = ["B", "KB", "MB", "GB", "TB"];
  let v = bytes;
  let u = 0;
  while (v >= 1024 && u < units.length - 1) {
    v /= 1024;
    u += 1;
  }
  return `${v >= 10 || u === 0 ? Math.round(v) : v.toFixed(1)} ${units[u]}`;
}

async function loadTorrents(): Promise<void> {
  const res = await send({ kind: "opal", action: "torrents" });
  const items = res.ok ? ((res.data as { torrents?: OpalTorrent[] })?.torrents ?? []) : [];
  torrentsCard.hidden = items.length === 0;
  if (!items.length) return;
  torrentsList.textContent = "";
  for (const t of items) {
    const li = document.createElement("li");
    li.className = "result torrent";
    const meta = document.createElement("div");
    meta.className = "result-meta";
    const pct = Math.max(0, Math.min(100, t.pct));
    // The detail line answers the question a percentage alone cannot: is it
    // moving? A torrent stuck at 3% with 0 seeds is not the same as one at 3%
    // pulling 4 MB/s, and both read "3%".
    meta.innerHTML =
      `<span class="result-title">${escapeHtml(t.name)}</span>` +
      `<span class="result-detail">${pct.toFixed(1)}% · ${fmtRate(t.rate)} · ${t.seeds} seed${t.seeds === 1 ? "" : "s"}${t.paused ? " · paused" : ""}</span>` +
      `<span class="bar"><span class="bar-fill" style="width:${pct}%"></span></span>`;
    li.append(meta);
    torrentsList.append(li);
  }
}

torrentsRefresh.addEventListener("click", loadTorrents);

// ── Downloads on the Opal machine ────────────────────────────────────────────

let downloadDir = "";

async function loadDownloads(): Promise<void> {
  const res = await send({ kind: "opal", action: "downloadsList", subdir: downloadDir });
  downloadsList.textContent = "";
  downloadsUp.hidden = downloadDir === "";
  const files = res.ok ? ((res.data as { files?: OpalFile[] })?.files ?? []) : [];
  if (!files.length) {
    const li = document.createElement("li");
    li.className = "results-empty";
    li.textContent = res.ok ? "Nothing here." : "Opal not reachable.";
    downloadsList.append(li);
    return;
  }
  for (const f of files) {
    const li = document.createElement("li");
    li.className = "result";
    const meta = document.createElement("div");
    meta.className = "result-meta";
    meta.innerHTML =
      `<span class="result-title">${f.is_dir ? "📁 " : ""}${escapeHtml(f.name)}</span>` +
      (f.is_dir ? "" : `<span class="result-detail">${fmtSize(f.size)}</span>`);
    li.append(meta);
    const btns = document.createElement("div");
    btns.className = "result-btns";
    const b = document.createElement("button");
    b.className = f.is_dir ? "mini-btn" : "mini-btn primary";
    b.textContent = f.is_dir ? "→" : "▶";
    b.title = f.is_dir ? "Open folder" : "Play in Opal";
    b.addEventListener("click", () => {
      const rel = downloadDir ? `${downloadDir}/${f.name}` : f.name;
      if (f.is_dir) {
        downloadDir = rel;
        loadDownloads();
      } else {
        act(`Playing ${f.name}`, { kind: "opal", action: "downloadsPlay", file: rel });
      }
    });
    btns.append(b);
    li.append(btns);
    downloadsList.append(li);
  }
}

downloadsRefresh.addEventListener("click", loadDownloads);
downloadsUp.addEventListener("click", () => {
  downloadDir = downloadDir.includes("/")
    ? downloadDir.slice(0, downloadDir.lastIndexOf("/"))
    : "";
  loadDownloads();
});

// ── Recent searches ──────────────────────────────────────────────────────────
//
// /api/history is Opal's SEARCH history — the queries typed in the app, not
// watched media. Clicking one re-runs it here, so a search started on the
// desktop can be continued in the browser.

async function loadHistory(): Promise<void> {
  const res = await send({ kind: "opal", action: "history" });
  historyList.textContent = "";
  const items = res.ok ? ((res.data as { items?: string[] })?.items ?? []) : [];
  if (!items.length) {
    const li = document.createElement("li");
    li.className = "results-empty";
    li.textContent = res.ok ? "No searches yet." : "Opal not reachable.";
    historyList.append(li);
    return;
  }
  for (const q of items.slice(0, 20)) {
    const li = document.createElement("li");
    li.className = "result";
    const meta = document.createElement("div");
    meta.className = "result-meta";
    meta.innerHTML = `<span class="result-title">${escapeHtml(q)}</span>`;
    li.append(meta);
    const btns = document.createElement("div");
    btns.className = "result-btns";
    const b = document.createElement("button");
    b.className = "mini-btn primary";
    b.textContent = "⌕";
    b.title = `Search "${q}" again`;
    b.addEventListener("click", () => {
      searchQ.value = q;
      runSearch();
      searchQ.scrollIntoView({ block: "nearest" });
    });
    btns.append(b);
    li.append(btns);
    historyList.append(li);
  }
}

historyRefresh.addEventListener("click", loadHistory);

// Both lists are inside a collapsed <details>. Fetch on first open rather than
// at panel load — a folder listing and a history read are wasted work for a
// section nobody expanded.
function loadOnFirstOpen(el: HTMLElement, load: () => void): void {
  const d = el.closest("details");
  if (!d) return;
  let loaded = false;
  d.addEventListener("toggle", () => {
    if (d.open && !loaded) {
      loaded = true;
      load();
    }
  });
}
loadOnFirstOpen(downloadsList, loadDownloads);
loadOnFirstOpen(historyList, loadHistory);

// ── Cast + watch party ───────────────────────────────────────────────────────

castFind.addEventListener("click", async () => {
  castFind.disabled = true;
  castListEl.textContent = "";
  const res = await send({ kind: "opal", action: "castDevices" });
  castFind.disabled = false;
  const devices = res.ok ? ((res.data as { devices?: Array<{ name?: string; id?: string }> })?.devices ?? []) : [];
  if (!devices.length) {
    const li = document.createElement("li");
    li.className = "results-empty";
    li.textContent = res.ok ? "No cast devices found." : "Opal not reachable.";
    castListEl.append(li);
    return;
  }
  devices.forEach((d) => {
    const li = document.createElement("li");
    li.className = "result";
    li.innerHTML = `<div class="result-meta"><span class="result-title">${escapeHtml(d.name ?? d.id ?? "device")}</span></div>`;
    const b = document.createElement("button");
    b.className = "mini-btn primary";
    b.textContent = "Cast";
    b.addEventListener("click", () => act("Casting", { kind: "opal", action: "castStart", device: d.id }));
    const wrap = document.createElement("div");
    wrap.className = "result-btns";
    wrap.append(b);
    li.append(wrap);
    castListEl.append(li);
  });
});

castStopBtn.addEventListener("click", () => act("Stopped casting", { kind: "opal", action: "castStop" }));

partyHostBtn.addEventListener("click", async () => {
  await act("Hosting watch party", { kind: "opal", action: "partyHost" });
  loadPartyStatus();
});
partyJoinBtn.addEventListener("click", async () => {
  const ip = partyIp.value.trim();
  if (!ip) return;
  await act(`Joining ${ip}`, { kind: "opal", action: "partyJoin", ip });
  loadPartyStatus();
});
partyLeaveBtn.addEventListener("click", async () => {
  await act("Left the party", { kind: "opal", action: "partyLeave" });
  loadPartyStatus();
});

/** Hosting or joining reported "✓" and then nothing — there was no way to see
 *  whether anyone connected, or to get out again. */
async function loadPartyStatus(): Promise<void> {
  const res = await send({ kind: "opal", action: "partyStatus" });
  if (!res.ok) {
    partyStatusEl.textContent = "Not in a watch party.";
    return;
  }
  const st = res.data as
    | { role?: string; connected?: boolean; peers?: number; host_ip?: string; status?: string }
    | undefined;
  if (!st || !st.role || st.role === "none" || st.role === "off") {
    partyStatusEl.textContent = "Not in a watch party.";
    return;
  }
  const peers = st.peers ?? 0;
  const where = st.host_ip ? ` · ${st.host_ip}` : "";
  partyStatusEl.textContent =
    `${st.role}${st.connected ? " · connected" : " · waiting"} · ${peers} peer${peers === 1 ? "" : "s"}${where}`;
}

// ── Status polling ────────────────────────────────────────────────────────────

let pollTimer: number | undefined;

let ticks = 0;

async function poll(): Promise<void> {
  const res = await send({ kind: "opal", action: "status" });
  if (res.ok) {
    statusDot.className = "dot ok";
    statusText.textContent = "Connected";
    setupCard.hidden = true;
    const st = res.data as OpalStatus | undefined;
    if (st && typeof st === "object") renderStatus(st);
    // Torrents move; everything else in the panel is pull-to-refresh. Every
    // 6th tick ≈ 9s — enough to watch a download climb without a request a
    // second for a card that is usually hidden.
    if (ticks % 6 === 0) loadTorrents();
    ticks += 1;
  } else if (res.needsSetup) {
    // Never set up. Not an error — a step nobody has taken yet.
    statusDot.className = "dot probing";
    statusText.textContent = "Not connected";
    setupCard.hidden = false;
  } else if (res.status === 401) {
    statusDot.className = "dot err";
    statusText.textContent = "Sign-in expired — open Settings";
    setupCard.hidden = false;
  } else {
    statusDot.className = "dot err";
    statusText.textContent = "Opal not running";
  }
}

function renderStatus(st: OpalStatus): void {
  npTitle.textContent = st.title && st.title !== "No media" ? st.title : "Nothing playing";
  playpauseBtn.textContent = st.paused ? "▶" : "⏸";
  npPos.textContent = fmt(st.pos);
  npDur.textContent = fmt(st.dur);
  if (!seeking) seek.value = String(st.dur > 0 ? Math.round((st.pos / st.dur) * 100) : 0);
  if (!volDragging) vol.value = String(Math.round(st.vol));
}

optionsLink.addEventListener("click", (e) => {
  e.preventDefault();
  chrome.runtime.openOptionsPage();
});
setupOpen.addEventListener("click", () => chrome.runtime.openOptionsPage());

// Re-detect when the active tab changes / navigates while the panel is open.
chrome.tabs.onActivated.addListener(() => loadDetection());
chrome.tabs.onUpdated.addListener((_id, info, tab) => {
  if (tab.active && info.status === "complete") loadDetection();
});

loadDetection();
loadQueue();
loadTorrents();
loadPartyStatus();
poll();
pollTimer = setInterval(poll, 1500) as unknown as number;
window.addEventListener("unload", () => {
  if (pollTimer) clearInterval(pollTimer);
});
