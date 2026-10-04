/**
 * The paired browser's calls to Opal, shared by the link, the sniffer and the
 * fetch worker. One credential: the `opb_` token from pairing, stored in
 * `chrome.storage.local` (never sync). It can reach only the few routes listed
 * in Opal's `browser_routes` (src/services/access_pure.zig).
 */

import { baseUrl, getSettings } from "./shared";

export interface StoredLink {
  token: string;
  id: number;
  label: string;
}

export interface BrowserResult {
  ok: boolean;
  status?: number;
  error?: string;
  data?: unknown;
}

export async function readLink(): Promise<StoredLink | null> {
  const got = await chrome.storage.local.get("browserLink");
  const l = got.browserLink as StoredLink | undefined;
  return l && typeof l.token === "string" && l.token ? l : null;
}

export interface CallOptions {
  timeoutMs?: number;
  /** Send `body` as given (plain text) instead of JSON. */
  rawText?: boolean;
}

export async function jsonFetch(
  path: string,
  method: "GET" | "POST",
  body: unknown,
  token: string,
  opts: CallOptions = {},
): Promise<BrowserResult> {
  const s = await getSettings();
  const headers: Record<string, string> = {};
  if (token) headers.Authorization = `Bearer ${token}`;
  if (body !== undefined) headers["Content-Type"] = opts.rawText ? "text/plain; charset=utf-8" : "application/json";
  try {
    const res = await fetch(`${baseUrl(s)}${path}`, {
      method,
      headers,
      body: body === undefined ? undefined : opts.rawText ? (body as BodyInit) : JSON.stringify(body),
      signal: AbortSignal.timeout(opts.timeoutMs ?? 8000),
    });
    const text = await res.text();
    let data: unknown = undefined;
    try {
      data = text ? JSON.parse(text) : undefined;
    } catch {
      data = text;
    }
    const err = (data as { error?: string } | undefined)?.error;
    return { ok: res.ok, status: res.status, data, error: res.ok ? undefined : err ?? `HTTP ${res.status}` };
  } catch {
    return {
      ok: false,
      error: "Opal is not reachable. Is the app running with \"Allow coding agents\" on in Settings?",
    };
  }
}
