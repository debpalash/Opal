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
  OpalQueueItem,
  OpalRequest,
  OpalResponse,
  OpalSearchResult,
  OpalStatus,
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
const castListEl = $<HTMLUListElement>("cast-list");
const partyHostBtn = $<HTMLButtonElement>("party-host");
const partyIp = $<HTMLInputElement>("party-ip");
const partyJoinBtn = $<HTMLButtonElement>("party-join");
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

partyHostBtn.addEventListener("click", () => act("Hosting watch party", { kind: "opal", action: "partyHost" }));
partyJoinBtn.addEventListener("click", () => {
  const ip = partyIp.value.trim();
  if (!ip) return;
  act(`Joining ${ip}`, { kind: "opal", action: "partyJoin", ip });
});

// ── Status polling ────────────────────────────────────────────────────────────

let pollTimer: number | undefined;

async function poll(): Promise<void> {
  const res = await send({ kind: "opal", action: "status" });
  if (res.ok) {
    statusDot.className = "dot ok";
    statusText.textContent = "Connected";
    const st = res.data as OpalStatus | undefined;
    if (st && typeof st === "object") renderStatus(st);
  } else if (res.status === 401) {
    statusDot.className = "dot err";
    statusText.textContent = "Token invalid — open Settings";
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

// Re-detect when the active tab changes / navigates while the panel is open.
chrome.tabs.onActivated.addListener(() => loadDetection());
chrome.tabs.onUpdated.addListener((_id, info, tab) => {
  if (tab.active && info.status === "complete") loadDetection();
});

loadDetection();
loadQueue();
poll();
pollTimer = setInterval(poll, 1500) as unknown as number;
window.addEventListener("unload", () => {
  if (pollTimer) clearInterval(pollTimer);
});
