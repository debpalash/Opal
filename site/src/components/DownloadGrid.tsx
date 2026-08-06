import { useEffect, useState } from "react";

/** One tile. `href` starts as the Releases page and is upgraded to the actual
 *  file once we know the newest release — so a rate-limited or blocked API
 *  costs nothing but a click. */
type Tile = {
  os: "mac" | "linux" | "windows" | "ext";
  icon: string;
  title: string;
  meta: string;
  /** Substrings that must ALL appear in an asset name for it to match. */
  match: string[][];
};

const RELEASES = "https://github.com/debpalash/Opal/releases";
const LATEST_API = "https://api.github.com/repos/debpalash/Opal/releases/latest";

const TILES: Tile[] = [
  { os: "mac", icon: "🍎", title: "macOS", meta: "Apple silicon · .dmg", match: [[".dmg"], ["macos", ".zip"]] },
  { os: "linux", icon: "🐧", title: "Linux", meta: "AppImage · .deb · .rpm", match: [[".appimage"]] },
  { os: "windows", icon: "🪟", title: "Windows", meta: ".msi · alpha", match: [[".msi"]] },
  { os: "ext", icon: "🧩", title: "Opal Connect", meta: "Chrome · Firefox", match: [["opal-connect", "chrome"]] },
];

type Asset = { name: string; browser_download_url: string };

function resolve(assets: Asset[], patterns: string[][]): string | null {
  for (const needles of patterns) {
    const hit = assets.find((a) => needles.every((n) => a.name.toLowerCase().includes(n)));
    if (hit) return hit.browser_download_url;
  }
  return null;
}

/** The platform this visitor is on, so the tile they want is marked. */
function detectOs(): Tile["os"] | null {
  if (typeof navigator === "undefined") return null;
  const ua = navigator.userAgent;
  if (/Mac/i.test(ua)) return "mac";
  if (/Win/i.test(ua)) return "windows";
  if (/Linux|X11|Android|CrOS/i.test(ua)) return "linux";
  return null;
}

export default function DownloadGrid() {
  const [links, setLinks] = useState<Partial<Record<Tile["os"], string>>>({});
  const [here, setHere] = useState<Tile["os"] | null>(null);

  useEffect(() => {
    setHere(detectOs());
    let live = true;
    fetch(LATEST_API)
      .then((r) => (r.ok ? r.json() : Promise.reject(new Error(String(r.status)))))
      .then((rel: { assets?: Asset[] }) => {
        if (!live) return;
        const assets = rel.assets ?? [];
        const next: Partial<Record<Tile["os"], string>> = {};
        for (const t of TILES) {
          const url = resolve(assets, t.match);
          if (url) next[t.os] = url;
        }
        setLinks(next);
      })
      .catch(() => {
        /* keep the Releases-page fallback */
      });
    return () => {
      live = false;
    };
  }, []);

  return (
    <div className="dl">
      {TILES.map((t) => (
        <a
          key={t.os}
          href={links[t.os] ?? RELEASES}
          className={here === t.os ? "yours" : undefined}
          data-os={t.os}
        >
          <span className="os">{t.icon}</span>
          <span className="grow">
            {t.title} <span className="meta">{t.meta}</span>
          </span>
          {here === t.os ? <span className="tag">your platform</span> : null}
        </a>
      ))}
    </div>
  );
}
