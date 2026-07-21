/**
 * Opal Connector — background service worker.
 *
 * The SINGLE place that talks to the local Opal JSON API. The content script and
 * the side panel send messages here; this worker owns the bearer token and does
 * the fetch. Because the worker holds `host_permissions` for 127.0.0.1/localhost,
 * these requests are NOT subject to page CORS, so no server-side CORS change is
 * needed (Opal already sets permissive headers anyway).
 *
 * It exposes Opal's full remote surface — send/sources, unified search, the whole
 * transport, queue, downloads, cast and watch-party. The action → endpoint map is
 * `OpalAction` in shared.ts; server side is src/services/remote.zig.
 */

import {
  baseUrl,
  getSettings,
  type Detection,
  type OpalFramework,
  type OpalRequest,
  type OpalResponse,
} from "./shared";

// ── Core: talk to Opal ──────────────────────────────────────────────────────

async function opalFetch(
  path: string,
  method: "GET" | "POST",
): Promise<OpalResponse> {
  const s = await getSettings();
  if (!s.token) {
    return { ok: false, error: "No API token set. Open the extension Settings." };
  }
  const url = `${baseUrl(s)}${path}`;
  try {
    const res = await fetch(url, {
      method,
      headers: { Authorization: `Bearer ${s.token}` },
    });
    let data: unknown = undefined;
    const text = await res.text();
    try {
      data = text ? JSON.parse(text) : undefined;
    } catch {
      data = text;
    }
    if (res.status === 401) {
      return { ok: false, status: 401, error: "Unauthorized — check the token in Settings." };
    }
    return { ok: res.ok, status: res.status, data };
  } catch {
    return {
      ok: false,
      error:
        "Opal is not reachable. Is the desktop app running with the Web Remote enabled?",
    };
  }
}

const enc = encodeURIComponent;

/** Route a high-level action to the right Opal endpoint. */
async function sendToOpal(req: OpalRequest): Promise<OpalResponse> {
  switch (req.action) {
    case "open": {
      const parts = [`url=${enc(req.url ?? "")}`];
      if (req.title) parts.push(`title=${enc(req.title)}`);
      if (req.art) parts.push(`art=${enc(req.art)}`);
      if (req.subtitle) parts.push(`subtitle=${enc(req.subtitle)}`);
      return opalFetch(`/api/open?${parts.join("&")}`, "POST");
    }
    case "download":
      return opalFetch(`/api/download/url?url=${enc(req.url ?? "")}`, "POST");
    case "search":
      return opalFetch(`/api/search?q=${enc(req.query ?? "")}`, "GET");
    case "status":
      return opalFetch(`/api/status`, "GET");
    case "ingest": {
      const parts = [
        `type=${enc(req.ingestType ?? "media")}`,
        `url=${enc(req.url ?? "")}`,
      ];
      if (req.title) parts.push(`title=${enc(req.title)}`);
      if (req.art) parts.push(`art=${enc(req.art)}`);
      if (req.subtitle) parts.push(`subtitle=${enc(req.subtitle)}`);
      return opalFetch(`/api/ingest?${parts.join("&")}`, "POST");
    }
    case "addSource":
      return opalFetch(
        `/api/source/add?framework=${enc(req.framework ?? "")}&base=${enc(req.base ?? "")}`,
        "POST",
      );
    case "playpause":
      return opalFetch(`/api/playpause`, "POST");
    case "seek":
      return opalFetch(`/api/seek_pct?v=${enc(String(Math.round(req.value ?? 0)))}`, "POST");
    case "volume":
      return opalFetch(`/api/volume?v=${enc(String(Math.round(req.value ?? 0)))}`, "POST");
    case "nextAudio":
      return opalFetch(`/api/next_audio`, "POST");
    case "nextSub":
      return opalFetch(`/api/next_sub`, "POST");
    case "load":
      return opalFetch(`/api/load?url=${enc(req.url ?? "")}`, "POST");
    // ── Transport (extra) ──
    case "seekFwd":
      return opalFetch(`/api/fwd`, "POST");
    case "seekBack":
      return opalFetch(`/api/back`, "POST");
    case "volUp":
      return opalFetch(`/api/vol_up`, "POST");
    case "volDown":
      return opalFetch(`/api/vol_down`, "POST");
    case "mute":
      return opalFetch(`/api/mute`, "POST");
    case "fullscreen":
      return opalFetch(`/api/fullscreen`, "POST");
    case "flip":
      return opalFetch(`/api/flip`, "POST");
    case "rotate":
      return opalFetch(`/api/rotate`, "POST");
    // ── Search / discovery ──
    case "unifiedSearch":
      return opalFetch(`/api/unified_search?q=${enc(req.query ?? "")}`, "GET");
    case "recommendations":
      return opalFetch(`/api/recommendations`, "GET");
    // ── Queue ──
    case "queueList":
      return opalFetch(`/api/queue`, "GET");
    case "queueMove":
      return opalFetch(
        `/api/queue/move?idx=${enc(String(req.idx ?? 0))}&dir=${enc(req.moveDir ?? "down")}`,
        "POST",
      );
    // ── Downloads ──
    case "downloadsList":
      return opalFetch(`/api/downloads?dir=${enc(req.subdir ?? "")}`, "GET");
    case "downloadsPlay":
      return opalFetch(`/api/downloads/play?file=${enc(req.file ?? "")}`, "POST");
    // ── Cast / watch-party ──
    case "castDevices":
      return opalFetch(`/api/cast/devices`, "GET");
    case "castStart":
      return opalFetch(
        `/api/cast/start${req.device ? `?device=${enc(req.device)}` : ""}`,
        "POST",
      );
    case "partyHost":
      return opalFetch(`/api/party/host`, "POST");
    case "partyJoin":
      return opalFetch(`/api/party/join?ip=${enc(req.ip ?? "")}`, "POST");
    case "partyStatus":
      return opalFetch(`/api/party/status`, "GET");
    default:
      return { ok: false, error: `Unknown action: ${(req as OpalRequest).action}` };
  }
}

// ── Notifications ───────────────────────────────────────────────────────────

function notify(title: string, message: string): void {
  try {
    chrome.notifications.create({
      type: "basic",
      iconUrl: chrome.runtime.getURL("images/icon-128.png"),
      title,
      message,
    });
  } catch {
    // notifications unavailable — non-fatal
  }
}

async function runAndNotify(label: string, req: OpalRequest): Promise<OpalResponse> {
  const res = await sendToOpal(req);
  if (res.ok) notify("Opal", `${label} ✓`);
  else notify("Opal", `${label} failed: ${res.error ?? res.status ?? "error"}`);
  return res;
}

// ── Side panel (Chrome) / sidebar (Firefox) ─────────────────────────────────
// Clicking the toolbar icon opens the persistent panel. Chrome needs an explicit
// opt-in; Firefox opens `sidebar_action` on click natively, so we feature-check.

function enableSidePanelOnActionClick(): void {
  const sp = (chrome as unknown as { sidePanel?: { setPanelBehavior?: (o: { openPanelOnActionClick: boolean }) => Promise<void> } }).sidePanel;
  if (sp?.setPanelBehavior) {
    sp.setPanelBehavior({ openPanelOnActionClick: true }).catch(() => {});
  }
}

// ── Content-script detection helper ─────────────────────────────────────────

async function detectTab(tabId: number): Promise<Detection | null> {
  try {
    return (await chrome.tabs.sendMessage(tabId, { kind: "detect" })) as Detection | null;
  } catch {
    return null;
  }
}

// ── Context menus ───────────────────────────────────────────────────────────

const MENU = {
  linkPlay: "opal-link-play",
  linkDownload: "opal-link-download",
  linkQueue: "opal-link-queue",
  selectionSearch: "opal-selection-search",
  pageSmart: "opal-page-smart", // context-aware: Read/Play/etc. based on detection
  pageAddSource: "opal-page-add-source",
  pageRead: "opal-page-read",
} as const;

function buildContextMenus(): void {
  chrome.contextMenus.removeAll(() => {
    chrome.contextMenus.create({
      id: MENU.linkPlay,
      title: "▶ Play in Opal",
      contexts: ["link", "video", "audio", "image"],
    });
    chrome.contextMenus.create({
      id: MENU.linkDownload,
      title: "⬇ Download with Opal",
      contexts: ["link", "video", "audio", "image"],
    });
    chrome.contextMenus.create({
      id: MENU.linkQueue,
      title: "＋ Queue in Opal",
      contexts: ["link", "video", "audio"],
    });
    chrome.contextMenus.create({
      id: MENU.selectionSearch,
      title: 'Search "%s" in Opal',
      contexts: ["selection"],
    });
    chrome.contextMenus.create({
      id: MENU.pageSmart,
      title: "Send this page to Opal",
      contexts: ["page", "frame"],
    });
    chrome.contextMenus.create({
      id: MENU.pageAddSource,
      title: "Add this site as an Opal source",
      contexts: ["page", "frame"],
    });
    chrome.contextMenus.create({
      id: MENU.pageRead,
      title: "📖 Read in Opal",
      contexts: ["page", "frame"],
    });
  });
}

chrome.runtime.onInstalled.addListener(() => {
  buildContextMenus();
  enableSidePanelOnActionClick();
});
chrome.runtime.onStartup.addListener(() => {
  buildContextMenus();
  enableSidePanelOnActionClick();
});
// Also run at worker load so behavior is set even without an install/startup event.
enableSidePanelOnActionClick();

/** Label a smart send by the detected page type so the toast reads naturally. */
function smartLabel(d: Detection): string {
  switch (d.pageType) {
    case "manga":
      return "Read chapter in Opal";
    case "novel":
      return "Read chapter in Opal";
    case "anime":
      return "Play episode in Opal";
    case "video":
    case "media":
      return "Play in Opal";
    case "magnet":
      return "Send torrent to Opal";
    default:
      return "Send to Opal";
  }
}

chrome.contextMenus.onClicked.addListener(async (info, tab) => {
  const linkTarget = info.linkUrl || info.srcUrl || info.pageUrl || tab?.url || "";
  switch (info.menuItemId) {
    case MENU.linkPlay:
      await runAndNotify("Play", { kind: "opal", action: "open", url: linkTarget });
      break;
    case MENU.linkDownload:
      await runAndNotify("Download", { kind: "opal", action: "download", url: linkTarget });
      break;
    case MENU.linkQueue:
      await runAndNotify("Queue", {
        kind: "opal",
        action: "ingest",
        ingestType: "queue",
        url: linkTarget,
      });
      break;
    case MENU.selectionSearch:
      await runAndNotify("Search", {
        kind: "opal",
        action: "search",
        query: info.selectionText ?? "",
      });
      break;
    case MENU.pageSmart: {
      const d = tab?.id ? await detectTab(tab.id) : null;
      if (!d) {
        await runAndNotify("Send", { kind: "opal", action: "open", url: linkTarget });
        break;
      }
      await runAndNotify(smartLabel(d), {
        kind: "opal",
        action: "ingest",
        ingestType: d.pageType,
        url: d.url || linkTarget,
        title: d.title,
        art: d.art,
        subtitle: d.subtitle,
      });
      break;
    }
    case MENU.pageAddSource: {
      const d = tab?.id ? await detectTab(tab.id) : null;
      if (!d || !d.framework) {
        notify("Opal", "No manga/novel source framework detected on this site.");
        break;
      }
      await addSourceAndNotify(d);
      break;
    }
    case MENU.pageRead:
      await runAndNotify("Read", {
        kind: "opal",
        action: "ingest",
        ingestType: "article",
        url: linkTarget,
      });
      break;
    default:
      break;
  }
});

async function addSourceAndNotify(d: Detection): Promise<OpalResponse> {
  if (!d.framework) return { ok: false, error: "no framework" };
  const res = await sendToOpal({
    kind: "opal",
    action: "addSource",
    framework: d.framework as OpalFramework,
    base: d.origin,
  });
  if (res.ok) notify("Opal", `Added ${d.siteName} — now searchable in Opal's Comics/Novels`);
  else notify("Opal", `Add source failed: ${res.error ?? res.status ?? "error"}`);
  return res;
}

// ── Messages from content script / side panel ───────────────────────────────

chrome.runtime.onMessage.addListener((msg, _sender, sendResponse) => {
  if (msg && msg.kind === "opal") {
    sendToOpal(msg as OpalRequest).then((res) => {
      if (msg.notify) {
        if (res.ok) notify("Opal", `${msg.label ?? "Sent"} ✓`);
        else notify("Opal", `${msg.label ?? "Action"} failed: ${res.error ?? "error"}`);
      }
      sendResponse(res);
    });
    return true; // keep the message channel open for the async response
  }
  return false;
});
