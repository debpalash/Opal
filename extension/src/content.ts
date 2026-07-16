/**
 * Opal Connector — content script.
 *
 * Runs on every page. Two jobs:
 *   1. Detect playable media (video/audio elements, og:video/og:audio meta,
 *      magnet links, direct media URLs, known streaming/reading site patterns)
 *      and, when found, inject an unobtrusive floating "▶ Opal" button inside a
 *      shadow root (so page CSS can't bleed in / out).
 *   2. Answer `scrape` messages from the background worker by extracting either
 *      the readable article text, the best media URL, or a chapter list.
 *
 * All network calls to Opal go through the background worker (message passing) —
 * the content script never fetches localhost itself.
 */

// ── Media / content detection ───────────────────────────────────────────────

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

/** Return the single best media/content URL for this page, or null. */
function detectBestMediaUrl(): string | null {
  // 1. og:video / og:audio meta (used by most streaming embeds).
  const og =
    metaContent('meta[property="og:video:secure_url"]') ||
    metaContent('meta[property="og:video:url"]') ||
    metaContent('meta[property="og:video"]') ||
    metaContent('meta[property="og:audio"]');
  if (og) return absoluteUrl(og);

  // 2. A <video>/<audio> element with a resolvable source.
  const media = document.querySelector<HTMLMediaElement>("video[src], audio[src]");
  if (media?.src) return media.src;
  const source = document.querySelector<HTMLSourceElement>(
    "video > source[src], audio > source[src]",
  );
  if (source?.src) return absoluteUrl(source.src);

  // 3. A magnet link anywhere on the page.
  const magnet = document.querySelector<HTMLAnchorElement>('a[href^="magnet:"]');
  if (magnet?.href) return magnet.href;

  // 4. A direct media / document link.
  const directLink = Array.from(document.querySelectorAll<HTMLAnchorElement>("a[href]")).find(
    (a) => MEDIA_EXT.test(a.href),
  );
  if (directLink?.href) return absoluteUrl(directLink.href);

  // 5. Known site patterns → hand the watch/chapter URL to Opal, which knows
  //    how to resolve it (YouTube, common streaming/manga/novel hosts).
  if (isKnownPlayablePage()) return location.href;

  return null;
}

function isKnownPlayablePage(): boolean {
  const h = location.hostname.replace(/^www\./, "");
  const p = location.pathname;
  // YouTube watch / shorts.
  if (/(^|\.)youtube\.com$/.test(h) && (/\/watch/.test(p) || /\/shorts\//.test(p))) return true;
  if (h === "youtu.be" && p.length > 1) return true;
  // Manga / novel chapter pages (heuristic: a /chapter/ or /chapter-N path).
  if (/\/chapter[-/]/i.test(p) || /-chapter-\d+/i.test(p)) return true;
  return false;
}

// ── Readability-style article extraction (heuristic) ────────────────────────

/**
 * Largest-text-block heuristic: score candidate block elements by the amount of
 * paragraph text they contain and pick the densest. Deliberately tiny — good
 * enough to hand a title + main text to Opal without vendoring Readability.
 */
function extractArticle(): { title: string; content: string } {
  const title =
    metaContent('meta[property="og:title"]') || document.title || location.href;

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

/** Collect a chapter / episode list if the page looks like an index. */
function extractChapters(): { title: string; items: string[] } {
  const title = metaContent('meta[property="og:title"]') || document.title;
  const anchors = Array.from(document.querySelectorAll<HTMLAnchorElement>("a[href]"))
    .filter((a) => /\/(chapter|episode|ep|vol)[-/ ]?\d+/i.test(a.href) || /-chapter-\d+/i.test(a.href))
    .map((a) => absoluteUrl(a.href));
  const items = Array.from(new Set(anchors));
  return { title, items };
}

// ── Scrape message handler ──────────────────────────────────────────────────

chrome.runtime.onMessage.addListener((msg, _sender, sendResponse) => {
  if (!msg || msg.kind !== "scrape") return false;

  const forceType: "article" | "media" | "chapters" | undefined = msg.forceType;

  if (forceType === "article") {
    const { title, content } = extractArticle();
    sendResponse({ type: "article", title, url: location.href, content });
    return false;
  }

  // Auto-detect: media first, then a chapter index, then fall back to article.
  const media = detectBestMediaUrl();
  if (media) {
    const title = metaContent('meta[property="og:title"]') || document.title;
    sendResponse({ type: "media", title, url: media });
    return false;
  }
  const chapters = extractChapters();
  if (chapters.items.length >= 2) {
    sendResponse({
      type: "chapters",
      title: chapters.title,
      url: chapters.items[0],
      items: chapters.items,
    });
    return false;
  }
  const { title, content } = extractArticle();
  sendResponse({ type: "article", title, url: location.href, content });
  return false;
});

// ── Floating "▶ Opal" button (shadow DOM) ───────────────────────────────────

let injected = false;

function injectButton(mediaUrl: string): void {
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
    .wrap { display: flex; gap: 6px; font-family: system-ui, sans-serif; }
    button {
      all: unset;
      cursor: pointer;
      background: #6b4bd6;
      color: #fff;
      font-size: 13px;
      font-weight: 600;
      padding: 8px 12px;
      border-radius: 999px;
      box-shadow: 0 3px 10px rgba(0,0,0,.3);
      transition: transform .08s ease, background .15s ease;
    }
    button:hover { background: #7d5fe6; transform: translateY(-1px); }
    button:active { transform: translateY(0); }
    button.secondary { background: #333; }
    button.secondary:hover { background: #444; }
    .close { background: transparent; color: #fff; opacity: .6; padding: 8px; }
    .close:hover { opacity: 1; background: transparent; }
  `;

  const wrap = document.createElement("div");
  wrap.className = "wrap";

  const play = document.createElement("button");
  play.textContent = "▶ Opal";
  play.title = "Play this in Opal";
  play.addEventListener("click", () => {
    chrome.runtime.sendMessage({
      kind: "opal",
      action: "open",
      url: mediaUrl,
      notify: true,
      label: "Play",
    });
  });

  const scrape = document.createElement("button");
  scrape.className = "secondary";
  scrape.textContent = "Scrape";
  scrape.title = "Send this page's content to Opal";
  scrape.addEventListener("click", () => {
    const media = detectBestMediaUrl();
    if (media) {
      const title = metaContent('meta[property="og:title"]') || document.title;
      chrome.runtime.sendMessage({
        kind: "opal",
        action: "ingest",
        ingestType: "media",
        url: media,
        title,
        notify: true,
        label: "Scrape",
      });
      return;
    }
    const { title } = extractArticle();
    chrome.runtime.sendMessage({
      kind: "opal",
      action: "ingest",
      ingestType: "article",
      url: location.href,
      title,
      notify: true,
      label: "Scrape",
    });
  });

  const close = document.createElement("button");
  close.className = "close";
  close.textContent = "✕";
  close.title = "Hide";
  close.addEventListener("click", () => host.remove());

  wrap.append(play, scrape, close);
  shadow.append(style, wrap);
  document.documentElement.appendChild(host);
}

function maybeInject(): void {
  const media = detectBestMediaUrl();
  if (media) injectButton(media);
}

// Initial pass + one delayed retry for SPAs that render media late.
maybeInject();
setTimeout(maybeInject, 2500);
