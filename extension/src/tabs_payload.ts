/**
 * The tab list sent to Opal: the pure part. Nothing here touches `chrome.*`, so
 * it runs under plain node for the unit tests (tests/tabs_payload.test.mjs).
 * Keep it free of imports and of syntax node cannot strip.
 *
 * The payload is trimmed on this side before it leaves the browser, and Opal
 * trims again: http(s) tabs only, no private (incognito) tabs, no query string
 * or fragment (they carry tokens), titles cut, at most 64 tabs.
 */

export const MAX_TABS = 64;
export const MAX_TITLE = 120;

export interface TabInfo {
  title?: string;
  url?: string;
  audible?: boolean;
  active?: boolean;
  incognito?: boolean;
}

export interface TabsPayload {
  tabs: Array<{ title: string; url: string; audible: boolean; active: boolean }>;
}

/** `scheme://host/path` with no query, fragment or credentials; null if not http(s). */
export function trimUrl(raw: string): string | null {
  let u: URL;
  try {
    u = new URL(raw);
  } catch {
    return null;
  }
  if (u.protocol !== "http:" && u.protocol !== "https:") return null;
  if (u.username || u.password) return null;
  return `${u.protocol}//${u.host}${u.pathname}`.slice(0, 300);
}

/** A tab with no <title> is titled with its own address, query string included.
 *  Wherever the title contains the full address (with or without the scheme) it
 *  is replaced by the trimmed address, so no query string leaves in a title. */
export function scrubTitle(title: string, fullUrl: string, trimmed: string): string {
  if (!fullUrl || fullUrl === trimmed) return title;
  const bare = (u: string) => u.replace(/^https?:\/\//i, "");
  return title.split(fullUrl).join(trimmed).split(bare(fullUrl)).join(bare(trimmed));
}

export function buildTabsPayload(tabs: TabInfo[]): TabsPayload {
  const out: TabsPayload["tabs"] = [];
  for (const t of tabs) {
    if (t.incognito) continue;
    const url = trimUrl(t.url ?? "");
    if (!url) continue;
    // eslint-disable-next-line no-control-regex
    let title = (t.title ?? "").replace(/[\u0000-\u001f\u007f]+/g, " ").replace(/\s+/g, " ").trim();
    // Scrub before cutting: a cut in the middle of the address would hide it from the match.
    title = scrubTitle(title, t.url ?? "", url).slice(0, MAX_TITLE);
    out.push({ title, url, audible: t.audible === true, active: t.active === true });
    if (out.length >= MAX_TABS) break;
  }
  return { tabs: out };
}
