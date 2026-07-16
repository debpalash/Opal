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

import type { Detection, OpalRequest, OpalResponse, OpalStatus } from "../shared";

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
const vol = $<HTMLInputElement>("vol");
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
backBtn.addEventListener("click", () => send({ kind: "opal", action: "seek", value: clampPct(Number(seek.value) - 5) }));
fwdBtn.addEventListener("click", () => send({ kind: "opal", action: "seek", value: clampPct(Number(seek.value) + 5) }));
nextAudioBtn.addEventListener("click", () => send({ kind: "opal", action: "nextAudio" }));
nextSubBtn.addEventListener("click", () => send({ kind: "opal", action: "nextSub" }));

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

function clampPct(v: number): number {
  return Math.max(0, Math.min(100, v));
}

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
poll();
pollTimer = setInterval(poll, 1500) as unknown as number;
window.addEventListener("unload", () => {
  if (pollTimer) clearInterval(pollTimer);
});
