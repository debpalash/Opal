/**
 * Opal Connector — content script.
 *
 * Runs on every page. Jobs:
 *   1. Detect the manga/novel *framework* a site is built on (Madara,
 *      MangaThemesia, HeanCMS, LightNovel-WP, ReadWN) so the extension can offer
 *      "Add this site as an Opal source".
 *   2. Classify the current page (video / manga / novel / anime / magnet /
 *      direct-media / article) and find the best URL + rich metadata (title,
 *      og:image cover, chapter/episode label) for a typed, card-worthy send.
 *   3. Inject an unobtrusive floating "▶ Opal" button (shadow-DOM isolated).
 *   4. Answer `detect` / `scrape` messages from the background worker.
 *
 * All network calls to Opal go through the background worker (message passing) —
 * the content script never fetches localhost itself.
 */

type OpalFramework =
  | "madara"
  | "mangathemesia"
  | "heancms"
  | "madara_novel"
  | "lightnovelwp"
  | "readwn";

type OpalPageType =
  | "video"
  | "manga"
  | "novel"
  | "anime"
  | "magnet"
  | "media"
  | "article";

interface Detection {
  pageType: OpalPageType;
  framework: OpalFramework | null;
  origin: string;
  siteName: string;
  url: string;
  title: string;
  art: string;
  subtitle: string;
}

const MEDIA_EXT = /\.(mp4|m3u8|mkv|webm|mov|avi|mp3|m4a|flac|ogg|wav|pdf|cbz|cbr|epub)(\?|#|$)/i;

function metaContent(selector: string): string | null {
  const el = document.querySelector<HTMLMetaElement>(selector);
  return el?.content?.trim() || null;
}

function absoluteUrl(href: string): string {
  try {
    return new URL(href, location.href).href;
  } catch {
    return href;
  }
}

function has(selector: string): boolean {
  try {
    return !!document.querySelector(selector);
  } catch {
    return false;
  }
}

// ── Framework detection ──────────────────────────────────────────────────────

/** Raw page HTML markers we scan once (cheap: outerHTML slice of <head>+body class). */
function pageSignals(): { bodyClass: string; generator: string; nextData: string } {
  const bodyClass = (document.body?.className || "").toLowerCase();
  const generator = (metaContent('meta[name="generator"]') || "").toLowerCase();
  // __NEXT_DATA__ (HeanCMS is a Next.js app) — read its JSON text if present.
  const nextEl = document.getElementById("__NEXT_DATA__");
  const nextData = nextEl?.textContent?.slice(0, 20000) || "";
  return { bodyClass, generator, nextData };
}

/**
 * Which Opal source engine (if any) this site is built on. Heuristics mirror the
 * task's framework fingerprints; manga-vs-novel disambiguation for the shared
 * Madara theme uses the reading surface (image chapters → manga, prose → novel).
 */
function detectFramework(): OpalFramework | null {
  const { bodyClass, generator, nextData } = pageSignals();

  // HeanCMS — Next.js manhwa API: a `series_slug` in the __NEXT_DATA__ JSON, or
  // an /api/ Next data pattern referencing series.
  if (/series_slug/.test(nextData) || (has('script[src*="/_next/"]') && /series_slug|"chapters"/.test(nextData))) {
    return "heancms";
  }

  // Madara (WordPress + Madara theme): wp-manga / madara body markers or a
  // chapter image container.
  const isMadara =
    /wp-manga|madara/.test(bodyClass) ||
    has(".wp-manga-chapter") ||
    has(".c-page__content .wp-manga") ||
    has(".reading-content .wp-manga-chapter-img") ||
    /madara/.test(generator);
  if (isMadara) {
    // Madara serves both. Image-based reading surface → comics; prose → novels.
    const hasImages = has(".reading-content img, .page-break img, .wp-manga-chapter-img");
    const hasProse = has(".reading-content .text-left, .cha-content, .text-left p, .reading-content p");
    if (hasProse && !hasImages) return "madara_novel";
    return "madara";
  }

  // MangaThemesia (WP manga theme): its signature reader / listing containers.
  if (has("#readerarea") || has(".listupd") || has(".ts-breadcrumb") || /mangathemesia/.test(generator)) {
    return "mangathemesia";
  }

  // LightNovel WP theme: .epcontent (chapter body) / .eplister (chapter list).
  if (has(".epcontent") || has(".eplister")) return "lightnovelwp";

  // ReadWN / MadStory novel theme: .chapter-content prose container.
  if (has(".chapter-content")) return "readwn";

  return null;
}

// ── Media / page-type detection ──────────────────────────────────────────────

/** Return the single best media/content URL for this page, or null. */
function detectBestMediaUrl(): string | null {
  const og =
    metaContent('meta[property="og:video:secure_url"]') ||
    metaContent('meta[property="og:video:url"]') ||
    metaContent('meta[property="og:video"]') ||
    metaContent('meta[property="og:audio"]');
  if (og) return absoluteUrl(og);

  const media = document.querySelector<HTMLMediaElement>("video[src], audio[src]");
  if (media?.src) return media.src;
  const source = document.querySelector<HTMLSourceElement>(
    "video > source[src], audio > source[src]",
  );
  if (source?.src) return absoluteUrl(source.src);

  const magnet = document.querySelector<HTMLAnchorElement>('a[href^="magnet:"]');
  if (magnet?.href) return magnet.href;

  const directLink = Array.from(document.querySelectorAll<HTMLAnchorElement>("a[href]")).find(
    (a) => MEDIA_EXT.test(a.href),
  );
  if (directLink?.href) return absoluteUrl(directLink.href);

  if (isKnownPlayablePage()) return location.href;
  return null;
}

function isKnownPlayablePage(): boolean {
  const h = location.hostname.replace(/^www\./, "");
  const p = location.pathname;
  if (/(^|\.)youtube\.com$/.test(h) && (/\/watch/.test(p) || /\/shorts\//.test(p))) return true;
  if (h === "youtu.be" && p.length > 1) return true;
  if (/\/chapter[-/]/i.test(p) || /-chapter-\d+/i.test(p)) return true;
  return false;
}

function isAnimePage(): boolean {
  const h = location.hostname.replace(/^www\./, "");
  const p = location.pathname;
  // Common anime streaming URL shapes.
  if (/\/(episode|watch)[-/]/i.test(p) && /(anime|watch|ep)/i.test(h + p)) return true;
  if (/-episode-\d+/i.test(p)) return true;
  return false;
}

/** Classify the page for a typed send. Framework wins for manga/novel sites. */
function detectPageType(framework: OpalFramework | null): OpalPageType {
  if (document.querySelector('a[href^="magnet:"]')) return "magnet";

  if (framework === "madara" || framework === "mangathemesia" || framework === "heancms") {
    return "manga";
  }
  if (framework === "madara_novel" || framework === "lightnovelwp" || framework === "readwn") {
    return "novel";
  }

  // Chapter path but no framework → still likely manga/novel; call it manga.
  if (/\/chapter[-/]/i.test(location.pathname) || /-chapter-\d+/i.test(location.pathname)) {
    return "manga";
  }
  if (isAnimePage()) return "anime";

  const og = metaContent('meta[property="og:video"]') || metaContent('meta[property="og:video:url"]');
  if (og || document.querySelector("video[src], video > source[src]")) return "video";
  if (isKnownPlayablePage()) return "video";

  const direct = Array.from(document.querySelectorAll<HTMLAnchorElement>("a[href]")).find((a) =>
    MEDIA_EXT.test(a.href),
  );
  if (direct || document.querySelector("audio[src], audio > source[src]")) return "media";

  return "article";
}

/** Chapter / episode label, e.g. "Chapter 42" or "Episode 5", if we can find one. */
function detectLabel(): string {
  const rx = /(chapter|chap|ch\.?|episode|ep\.?|vol(?:ume)?)\s*[-#:]?\s*(\d+(?:\.\d+)?)/i;
  const fromTitle = (metaContent('meta[property="og:title"]') || document.title || "").match(rx);
  if (fromTitle) return `${cap(fromTitle[1])} ${fromTitle[2]}`;
  for (const sel of ["h1", ".active a", ".wp-manga-chapter.active a", "#chapter option[selected]"]) {
    const el = document.querySelector(sel);
    const m = (el?.textContent || "").match(rx);
    if (m) return `${cap(m[1])} ${m[2]}`;
  }
  return "";
}

function cap(s: string): string {
  const t = s.replace(/\.$/, "");
  if (/^ch/i.test(t) && t.length <= 4) return "Chapter";
  if (/^ep/i.test(t) && t.length <= 4) return "Episode";
  if (/^vol/i.test(t)) return "Volume";
  return t.charAt(0).toUpperCase() + t.slice(1).toLowerCase();
}

function siteName(): string {
  return (
    metaContent('meta[property="og:site_name"]') ||
    location.hostname.replace(/^www\./, "")
  );
}

/** Full page analysis for the side panel + context menus. */
function analyze(): Detection {
  const framework = detectFramework();
  const pageType = detectPageType(framework);
  const media = detectBestMediaUrl();
  const title = metaContent('meta[property="og:title"]') || document.title || location.href;
  const art =
    metaContent('meta[property="og:image:secure_url"]') ||
    metaContent('meta[property="og:image"]') ||
    metaContent('meta[name="twitter:image"]') ||
    "";
  return {
    pageType,
    framework,
    origin: location.origin,
    siteName: siteName(),
    url: pageType === "manga" || pageType === "novel" || pageType === "anime" ? location.href : media || location.href,
    title,
    art: art ? absoluteUrl(art) : "",
    subtitle: detectLabel(),
  };
}

// ── Readability-style article extraction (heuristic) ────────────────────────

function extractArticle(): { title: string; content: string } {
  const title = metaContent('meta[property="og:title"]') || document.title || location.href;
  const article = document.querySelector("article");
  let best: Element | null = article;
  let bestScore = article ? scoreBlock(article) : 0;

  if (!best) {
    const candidates = document.querySelectorAll(
      "main, [role=main], .post, .article, .entry-content, .content, #content, section, div",
    );
    candidates.forEach((el) => {
      const score = scoreBlock(el);
      if (score > bestScore) {
        best = el;
        bestScore = score;
      }
    });
  }

  const paras = best
    ? Array.from(best.querySelectorAll("p, h1, h2, h3, li"))
        .map((p) => (p.textContent || "").trim())
        .filter((t) => t.length > 0)
    : [];
  const content = paras.join("\n\n").slice(0, 200000);
  return { title, content };
}

function scoreBlock(el: Element): number {
  const paras = el.querySelectorAll("p");
  let len = 0;
  paras.forEach((p) => (len += (p.textContent || "").length));
  return len;
}

function extractChapters(): { title: string; items: string[] } {
  const title = metaContent('meta[property="og:title"]') || document.title;
  const anchors = Array.from(document.querySelectorAll<HTMLAnchorElement>("a[href]"))
    .filter((a) => /\/(chapter|episode|ep|vol)[-/ ]?\d+/i.test(a.href) || /-chapter-\d+/i.test(a.href))
    .map((a) => absoluteUrl(a.href));
  const items = Array.from(new Set(anchors));
  return { title, items };
}

// ── Message handlers ─────────────────────────────────────────────────────────

chrome.runtime.onMessage.addListener((msg, _sender, sendResponse) => {
  if (!msg) return false;

  if (msg.kind === "detect") {
    sendResponse(analyze());
    return false;
  }

  if (msg.kind !== "scrape") return false;

  const forceType: "article" | "media" | "chapters" | undefined = msg.forceType;
  if (forceType === "article") {
    const { title, content } = extractArticle();
    sendResponse({ type: "article", title, url: location.href, content });
    return false;
  }

  const media = detectBestMediaUrl();
  if (media) {
    const title = metaContent('meta[property="og:title"]') || document.title;
    sendResponse({ type: "media", title, url: media });
    return false;
  }
  const chapters = extractChapters();
  if (chapters.items.length >= 2) {
    sendResponse({ type: "chapters", title: chapters.title, url: chapters.items[0], items: chapters.items });
    return false;
  }
  const { title, content } = extractArticle();
  sendResponse({ type: "article", title, url: location.href, content });
  return false;
});

// ── Floating "▶ Opal" button (shadow DOM, Opal-tinted) ──────────────────────

let injected = false;

function injectButton(d: Detection): void {
  if (injected) return;
  injected = true;

  const host = document.createElement("div");
  host.id = "opal-connector-host";
  host.style.all = "initial";
  host.style.position = "fixed";
  host.style.zIndex = "2147483647";
  host.style.bottom = "20px";
  host.style.right = "20px";
  const shadow = host.attachShadow({ mode: "open" });

  const style = document.createElement("style");
  style.textContent = `
    .wrap { display: flex; gap: 6px; align-items: center; font-family: system-ui, sans-serif; }
    button {
      all: unset; cursor: pointer; color: #fff; font-size: 13px; font-weight: 600;
      padding: 8px 13px; border-radius: 999px;
      background: linear-gradient(135deg, #7c5cff, #6b4bd6);
      box-shadow: 0 4px 14px rgba(108,76,214,.45);
      transition: transform .08s ease, filter .15s ease;
    }
    button:hover { filter: brightness(1.08); transform: translateY(-1px); }
    button:active { transform: translateY(0); }
    button.secondary { background: #26262e; box-shadow: 0 3px 10px rgba(0,0,0,.35); }
    button.secondary:hover { background: #33333d; }
    .close { background: transparent; color: #fff; opacity: .6; padding: 8px; box-shadow: none; }
    .close:hover { opacity: 1; background: transparent; filter: none; }
  `;

  const wrap = document.createElement("div");
  wrap.className = "wrap";

  const label = d.pageType === "manga" || d.pageType === "novel" ? "◆ Read in Opal" : "◆ Opal";
  const play = document.createElement("button");
  play.textContent = label;
  play.title = "Send this to Opal";
  play.addEventListener("click", () => {
    chrome.runtime.sendMessage({
      kind: "opal",
      action: "ingest",
      ingestType: d.pageType,
      url: d.url,
      title: d.title,
      art: d.art,
      subtitle: d.subtitle,
      notify: true,
      label: "Sent",
    });
  });
  wrap.append(play);

  // "Add this site as an Opal source" appears only on recognised source sites.
  if (d.framework) {
    const add = document.createElement("button");
    add.className = "secondary";
    add.textContent = "＋ Source";
    add.title = `Add ${d.siteName} as an Opal source`;
    add.addEventListener("click", () => {
      chrome.runtime.sendMessage({
        kind: "opal",
        action: "addSource",
        framework: d.framework,
        base: d.origin,
        notify: true,
        label: `Added ${d.siteName}`,
      });
    });
    wrap.append(add);
  }

  const close = document.createElement("button");
  close.className = "close";
  close.textContent = "✕";
  close.title = "Hide";
  close.addEventListener("click", () => host.remove());
  wrap.append(close);

  shadow.append(style, wrap);
  document.documentElement.appendChild(host);
}

function maybeInject(): void {
  const d = analyze();
  // Show the button when there's something worth sending or a source to add.
  if (d.framework || d.pageType !== "article" || detectBestMediaUrl()) injectButton(d);
}

maybeInject();
setTimeout(maybeInject, 2500);
