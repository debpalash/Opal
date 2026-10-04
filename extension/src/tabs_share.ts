/**
 * Share the tab list with Opal's agents (background side).
 *
 * Three things must all be true before a single tab title leaves this browser:
 *   1. the user turned it on here (the "Allow tab titles" button in the side
 *      panel, which asks for the optional `tabs` permission in that same click),
 *   2. the browser still grants that permission,
 *   3. the user's switch in Opal (Settings > Agent Access > Share tab list with
 *      agents) is on. Opal tells this extension through its `/api/browser/me`
 *      answer; the server refuses a report with the switch off regardless.
 * Opal keeps the list in memory only and shows agents titles plus host and path.
 * What this side sends is already trimmed: http(s) tabs only, no private
 * (incognito) tabs, no query string, no fragment.
 */

import { jsonFetch, readLink } from "./link_api";
import { buildTabsPayload, type TabInfo } from "./tabs_payload";

const OPT_IN_KEY = "tabsShare";
const ME_TTL_MS = 20_000;
const MIN_GAP_MS = 4_000;

let opalOn = false;
let opalCheckedAt = 0;
let lastKey = "";
let lastSentAt = 0;
let timer: ReturnType<typeof setTimeout> | undefined;

export async function tabsPermissionGranted(): Promise<boolean> {
  try {
    return await (chrome.permissions.contains({ permissions: ["tabs"] }) as unknown as Promise<boolean>);
  } catch {
    return false;
  }
}

async function optedIn(): Promise<boolean> {
  const got = await chrome.storage.local.get(OPT_IN_KEY);
  return got[OPT_IN_KEY] === true;
}

/** Ask Opal whether the user's switch is on. A flag only, never content. */
async function refreshOpalSwitch(force: boolean): Promise<boolean> {
  const link = await readLink();
  if (!link) return false;
  if (!force && Date.now() - opalCheckedAt < ME_TTL_MS) return opalOn;
  const res = await jsonFetch("/api/browser/me", "GET", undefined, link.token);
  opalCheckedAt = Date.now();
  opalOn = res.ok && (res.data as { share_tabs?: boolean } | undefined)?.share_tabs === true;
  return opalOn;
}

export interface TabsState {
  /** The user turned it on in this extension. */
  enabled: boolean;
  /** The browser grants the optional `tabs` permission. */
  granted: boolean;
  /** Opal's switch is on. */
  opalOn: boolean;
}

export async function tabsState(): Promise<TabsState> {
  return { enabled: await optedIn(), granted: await tabsPermissionGranted(), opalOn: await refreshOpalSwitch(true) };
}

/** Called after the panel obtained the permission in the user's click. */
export async function enableTabs(): Promise<TabsState> {
  if (!(await tabsPermissionGranted())) return tabsState();
  await chrome.storage.local.set({ [OPT_IN_KEY]: true });
  lastKey = "";
  scheduleReport(0);
  return tabsState();
}

/** Stop sharing now: forget the opt-in and send Opal an empty list so what it
 *  holds is replaced at once (it is refused harmlessly if its switch is off). */
export async function disableTabs(): Promise<TabsState> {
  await chrome.storage.local.set({ [OPT_IN_KEY]: false });
  const link = await readLink();
  if (link) await jsonFetch("/api/browser/tabs", "POST", { tabs: [] }, link.token);
  lastKey = "";
  return tabsState();
}

/** Send the tab list if all three consents are present and it changed (or a
 *  minute passed, so Opal can tell a quiet browser from a closed one). */
export async function reportTabs(force = false): Promise<void> {
  if (!(await optedIn())) return;
  if (!(await tabsPermissionGranted())) return;
  const link = await readLink();
  if (!link) return;
  if (!(await refreshOpalSwitch(false))) return;
  let all: chrome.tabs.Tab[];
  try {
    all = await chrome.tabs.query({});
  } catch {
    return;
  }
  const payload = buildTabsPayload(all as unknown as TabInfo[]);
  const key = JSON.stringify(payload);
  const now = Date.now();
  if (!force && key === lastKey && now - lastSentAt < 60_000) return;
  if (now - lastSentAt < MIN_GAP_MS && key !== lastKey) {
    scheduleReport(MIN_GAP_MS);
    return;
  }
  const res = await jsonFetch("/api/browser/tabs", "POST", payload, link.token);
  lastKey = key;
  lastSentAt = now;
  if (res.status === 403) {
    // Opal's switch went off since the last check: stop until it is on again.
    opalOn = false;
    opalCheckedAt = Date.now();
  }
  if (res.status === 401) await chrome.storage.local.remove("browserLink");
}

export function scheduleReport(delayMs = 5000): void {
  if (timer) clearTimeout(timer);
  timer = setTimeout(() => {
    timer = undefined;
    void reportTabs();
  }, delayMs);
}

try {
  chrome.tabs.onUpdated.addListener((_id, info) => {
    if (info.title !== undefined || info.url !== undefined || info.audible !== undefined || info.status === "complete") scheduleReport();
  });
  chrome.tabs.onRemoved.addListener(() => scheduleReport());
  chrome.tabs.onCreated.addListener(() => scheduleReport());
  chrome.tabs.onActivated.addListener(() => scheduleReport());
  // Taking the permission away in the browser's own UI ends the opt-in.
  chrome.permissions.onRemoved.addListener((p) => {
    if (p.permissions?.includes("tabs")) void chrome.storage.local.set({ [OPT_IN_KEY]: false });
  });
} catch {
  // tabs events unavailable: the minute alarm still reports
}
