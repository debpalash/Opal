/**
 * Opal Connector — background service worker.
 *
 * The SINGLE place that talks to the local Opal JSON API. Content scripts and
 * the popup send messages here; this worker owns the bearer token and does the
 * fetch. Because the worker holds `host_permissions` for 127.0.0.1/localhost,
 * these requests are NOT subject to page CORS, so no server-side CORS change is
 * needed (Opal already sets permissive headers anyway).
 *
 * Endpoints (see src/services/remote.zig):
 *   POST /api/open?url=<enc>          play / route a URL, magnet or file path
 *   POST /api/download/url?url=<enc>  hand a URL to Opal's downloader
 *   GET  /api/search?q=<enc>          universal search
 *   GET  /api/status                  player / connection status
 *   POST /api/ingest?type=&url=&title= scraped page → Opal
 */

import {
  baseUrl,
  getSettings,
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
    return { ok: false, error: "No API token set. Open the extension Options." };
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
      return { ok: false, status: 401, error: "Unauthorized — check the token in Options." };
    }
    return { ok: res.ok, status: res.status, data };
  } catch (e) {
    return {
      ok: false,
      error:
        "Opal is not reachable. Is the desktop app running with the Web Remote enabled?",
    };
  }
}

/** Route a high-level action to the right Opal endpoint. */
async function sendToOpal(req: OpalRequest): Promise<OpalResponse> {
  switch (req.action) {
    case "open":
      return opalFetch(`/api/open?url=${encodeURIComponent(req.url ?? "")}`, "POST");
    case "download":
      return opalFetch(
        `/api/download/url?url=${encodeURIComponent(req.url ?? "")}`,
        "POST",
      );
    case "search":
      return opalFetch(`/api/search?q=${encodeURIComponent(req.query ?? "")}`, "GET");
    case "status":
      return opalFetch(`/api/status`, "GET");
    case "ingest": {
      const parts = [
        `type=${encodeURIComponent(req.ingestType ?? "media")}`,
        `url=${encodeURIComponent(req.url ?? "")}`,
      ];
      if (req.title) parts.push(`title=${encodeURIComponent(req.title)}`);
      return opalFetch(`/api/ingest?${parts.join("&")}`, "POST");
    }
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
  if (res.ok) {
    notify("Opal", `${label} ✓`);
  } else {
    notify("Opal", `${label} failed: ${res.error ?? res.status ?? "error"}`);
  }
  return res;
}

// ── Context menus ───────────────────────────────────────────────────────────

const MENU = {
  linkPlay: "opal-link-play",
  linkDownload: "opal-link-download",
  linkSend: "opal-link-send",
  selectionSearch: "opal-selection-search",
  pageRead: "opal-page-read",
  pageScrape: "opal-page-scrape",
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
      id: MENU.linkSend,
      title: "Send to Opal",
      contexts: ["link"],
    });
    chrome.contextMenus.create({
      id: MENU.selectionSearch,
      title: 'Search "%s" in Opal',
      contexts: ["selection"],
    });
    chrome.contextMenus.create({
      id: MENU.pageRead,
      title: "📖 Read in Opal",
      contexts: ["page", "frame"],
    });
    chrome.contextMenus.create({
      id: MENU.pageScrape,
      title: "Scrape page → Opal",
      contexts: ["page", "frame"],
    });
  });
}

chrome.runtime.onInstalled.addListener(buildContextMenus);
chrome.runtime.onStartup.addListener(buildContextMenus);

chrome.contextMenus.onClicked.addListener(async (info, tab) => {
  const linkTarget = info.linkUrl || info.srcUrl || info.pageUrl || tab?.url || "";
  switch (info.menuItemId) {
    case MENU.linkPlay:
      await runAndNotify("Play", { kind: "opal", action: "open", url: linkTarget });
      break;
    case MENU.linkDownload:
      await runAndNotify("Download", {
        kind: "opal",
        action: "download",
        url: linkTarget,
      });
      break;
    case MENU.linkSend:
      await runAndNotify("Send", { kind: "opal", action: "open", url: linkTarget });
      break;
    case MENU.selectionSearch:
      await runAndNotify("Search", {
        kind: "opal",
        action: "search",
        query: info.selectionText ?? "",
      });
      break;
    case MENU.pageRead:
      // Ask the content script to extract readable content, then ingest it.
      await scrapeActiveTab(tab, "article", "Read");
      break;
    case MENU.pageScrape:
      await scrapeActiveTab(tab, undefined, "Scrape");
      break;
    default:
      break;
  }
});

/**
 * Ask the content script in `tab` to scrape the page, then POST the result to
 * /api/ingest. `forceType` pins the ingest type (Read → article); otherwise the
 * content script's own detection (media / chapters / article) is used.
 */
async function scrapeActiveTab(
  tab: chrome.tabs.Tab | undefined,
  forceType: "article" | "media" | "chapters" | undefined,
  label: string,
): Promise<void> {
  if (!tab?.id) {
    notify("Opal", `${label} failed: no active tab`);
    return;
  }
  try {
    const scraped = (await chrome.tabs.sendMessage(tab.id, {
      kind: "scrape",
      forceType,
    })) as {
      type: "article" | "media" | "chapters";
      title: string;
      url: string;
    } | null;
    if (!scraped || !scraped.url) {
      notify("Opal", `${label} failed: nothing detected on the page`);
      return;
    }
    await runAndNotify(label, {
      kind: "opal",
      action: "ingest",
      ingestType: forceType ?? scraped.type,
      url: scraped.url,
      title: scraped.title,
    });
  } catch {
    notify("Opal", `${label} failed: content script not available on this page`);
  }
}

// ── Messages from content script / popup ────────────────────────────────────

chrome.runtime.onMessage.addListener((msg, _sender, sendResponse) => {
  if (msg && msg.kind === "opal") {
    // Popup / content-script driven action. Reply async.
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
