/**
 * Shared types + settings helpers used by the background worker, side panel and
 * options page. Kept dependency-free so it bundles cleanly into every context.
 */

export interface OpalSettings {
  host: string;
  port: number;
  token: string;
  /** Default action for the toolbar / floating button send. */
  defaultAction: "play" | "queue" | "download";
}

export const DEFAULT_SETTINGS: OpalSettings = {
  host: "127.0.0.1",
  port: 41595,
  token: "",
  defaultAction: "play",
};

/** Read persisted settings (chrome.storage.sync), falling back to defaults. */
export async function getSettings(): Promise<OpalSettings> {
  const stored = await chrome.storage.sync.get(
    DEFAULT_SETTINGS as unknown as Record<string, unknown>,
  );
  const da = stored.defaultAction as OpalSettings["defaultAction"];
  return {
    host: (stored.host as string) || DEFAULT_SETTINGS.host,
    port: Number(stored.port) || DEFAULT_SETTINGS.port,
    token: (stored.token as string) || "",
    defaultAction:
      da === "queue" || da === "download" || da === "play"
        ? da
        : DEFAULT_SETTINGS.defaultAction,
  };
}

export async function saveSettings(s: OpalSettings): Promise<void> {
  await chrome.storage.sync.set(s);
}

export function baseUrl(s: OpalSettings): string {
  return `http://${s.host}:${s.port}`;
}

// ── Framework detection (manga / novel source engines Opal understands) ──────
// These IDs map 1:1 to Opal's source_config engine IDs (see comics.zig /
// novels.zig), so "Add this site as an Opal source" can install them directly.
export type OpalFramework =
  | "madara" // WordPress + Madara manga theme
  | "mangathemesia" // MangaThemesia (WP manga)
  | "heancms" // HeanCMS (Next.js manhwa API)
  | "madara_novel" // Madara serving novels
  | "lightnovelwp" // LightNovel WP theme
  | "readwn"; // ReadWN / MadStory novel theme

/** How a page was classified — drives the typed-send hint + the right menu label. */
export type OpalPageType =
  | "video"
  | "manga"
  | "novel"
  | "anime"
  | "magnet"
  | "media"
  | "article";

/** Result of the content script's page analysis, consumed by the side panel. */
export interface Detection {
  pageType: OpalPageType;
  framework: OpalFramework | null;
  /** Site origin (scheme + host), used as the source `base`. */
  origin: string;
  siteName: string;
  /** Best URL to send (media/chapter/page). */
  url: string;
  title: string;
  /** og:image cover / poster, if any. */
  art: string;
  /** Chapter / episode label, if detected. */
  subtitle: string;
}

/** Actions the side panel / content script ask the background worker to perform. */
export type OpalAction =
  | "open" // POST /api/open?url=&title=&art=&subtitle=
  | "download" // POST /api/download/url?url=
  | "search" // GET  /api/search?q=
  | "ingest" // POST /api/ingest?type=&url=&title=&art=&subtitle=
  | "addSource" // POST /api/source/add?framework=&base=
  | "status" // GET  /api/status         — now-playing / connection probe
  | "playpause" // POST /api/playpause
  | "seek" // POST /api/seek_pct?v=
  | "volume" // POST /api/volume?v=
  | "nextAudio" // POST /api/next_audio
  | "nextSub"; // POST /api/next_sub

export type OpalIngestType =
  | OpalPageType
  | "chapters"
  | "queue";

export interface OpalRequest {
  kind: "opal";
  action: OpalAction;
  url?: string;
  query?: string;
  ingestType?: OpalIngestType;
  title?: string;
  art?: string;
  subtitle?: string;
  framework?: OpalFramework;
  base?: string;
  /** seek target percent (0-100) / volume (0-150). */
  value?: number;
  notify?: boolean;
  label?: string;
}

export interface OpalStatus {
  pos: number;
  dur: number;
  vol: number;
  paused: boolean;
  title: string;
}

export interface OpalResponse {
  ok: boolean;
  status?: number;
  error?: string;
  data?: unknown;
}
