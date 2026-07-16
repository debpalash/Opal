/**
 * Shared types + settings helpers used by the background worker, popup and
 * options page. Kept dependency-free so it bundles cleanly into every context.
 */

export interface OpalSettings {
  host: string;
  port: number;
  token: string;
}

export const DEFAULT_SETTINGS: OpalSettings = {
  host: "127.0.0.1",
  port: 41595,
  token: "",
};

/** Read persisted settings (chrome.storage.sync), falling back to defaults. */
export async function getSettings(): Promise<OpalSettings> {
  const stored = await chrome.storage.sync.get(
    DEFAULT_SETTINGS as unknown as Record<string, unknown>,
  );
  return {
    host: (stored.host as string) || DEFAULT_SETTINGS.host,
    port: Number(stored.port) || DEFAULT_SETTINGS.port,
    token: (stored.token as string) || "",
  };
}

export async function saveSettings(s: OpalSettings): Promise<void> {
  await chrome.storage.sync.set(s);
}

export function baseUrl(s: OpalSettings): string {
  return `http://${s.host}:${s.port}`;
}

/** Actions the popup / content script ask the background worker to perform. */
export type OpalAction =
  | "open" // POST /api/open?url=      — play / route in Opal
  | "download" // POST /api/download/url?url=
  | "search" // GET  /api/search?q=
  | "ingest" // POST /api/ingest?type=&url=&title=
  | "status"; // GET  /api/status         — connection probe

export interface OpalRequest {
  kind: "opal";
  action: OpalAction;
  url?: string;
  query?: string;
  ingestType?: "article" | "media" | "chapters";
  title?: string;
}

export interface OpalResponse {
  ok: boolean;
  status?: number;
  error?: string;
  data?: unknown;
}
