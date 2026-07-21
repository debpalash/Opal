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
  // ── Send / sources ──
  | "open" // POST /api/open?url=&title=&art=&subtitle=
  | "download" // POST /api/download/url?url=
  | "ingest" // POST /api/ingest?type=&url=&title=&art=&subtitle=
  | "addSource" // POST /api/source/add?framework=&base=
  | "load" // POST /api/load?url=          — load into the ACTIVE player
  // ── Search / discovery ──
  | "search" // GET  /api/search?q=          — torrent search
  | "unifiedSearch" // GET  /api/unified_search?q=  — every source, ranked
  | "recommendations" // GET  /api/recommendations
  // ── Transport ──
  | "status" // GET  /api/status            — now-playing / connection probe
  | "playpause" // POST /api/playpause
  | "seek" // POST /api/seek_pct?v=
  | "seekFwd" // POST /api/fwd               — +10s
  | "seekBack" // POST /api/back              — −10s
  | "volume" // POST /api/volume?v=
  | "volUp" // POST /api/vol_up
  | "volDown" // POST /api/vol_down
  | "mute" // POST /api/mute
  | "fullscreen" // POST /api/fullscreen
  | "flip" // POST /api/flip
  | "rotate" // POST /api/rotate
  | "nextAudio" // POST /api/next_audio
  | "nextSub" // POST /api/next_sub
  // ── Queue ──
  | "queueList" // GET  /api/queue
  | "queueMove" // POST /api/queue/move?idx=&dir=up|down
  // ── Downloads ──
  | "downloadsList" // GET  /api/downloads?dir=
  | "downloadsPlay" // POST /api/downloads/play?file=
  // ── Cast / watch-party ──
  | "castDevices" // GET  /api/cast/devices
  | "castStart" // POST /api/cast/start
  | "partyHost" // POST /api/party/host
  | "partyJoin" // POST /api/party/join?ip=
  | "partyStatus"; // GET  /api/party/status

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
  /** queueMove: item index + direction. */
  idx?: number;
  moveDir?: "up" | "down";
  /** downloadsList subdir / downloadsPlay filename. */
  subdir?: string;
  file?: string;
  /** partyJoin host IP. */
  ip?: string;
  /** castStart target device id. */
  device?: string;
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

/** A row from GET /api/queue. */
export interface OpalQueueItem {
  url: string;
  played: boolean;
}

/** A row from GET /api/unified_search. `action` tells you how `data` plays:
 *  magnet → data is a magnet/URL; yt_play → data is a YouTube video id;
 *  tmdb_detail / anime_detail / jf_play / jf_browse → an in-app id (info only). */
export interface OpalSearchResult {
  source: string;
  title: string;
  detail: string;
  action: string;
  data: string;
}

export interface OpalUnifiedResults {
  loading: boolean;
  results: OpalSearchResult[];
}

export interface OpalResponse {
  ok: boolean;
  status?: number;
  error?: string;
  data?: unknown;
}
