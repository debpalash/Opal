/**
 * One fetch of the release history, shared by every island on the page.
 *
 * Several islands want release data — the hero badge, the download menu in the
 * nav, the download grid, the thanks page — and the counts have to come from the
 * whole history: a per-platform total that only counted the newest tag would
 * reset to nearly zero on every release day. The list endpoint answers all of it
 * in a single unauthenticated request, which matters: api.github.com allows 60
 * an hour per IP, and every island firing its own would burn that on one visit.
 */
const REPO_API = "https://api.github.com/repos/debpalash/Opal";
const LIST = `${REPO_API}/releases?per_page=100`;

export const REPO = "https://github.com/debpalash/Opal";

export type Asset = {
  name: string;
  browser_download_url: string;
  download_count: number;
  size: number;
};

export type Release = {
  tag_name: string;
  draft: boolean;
  prerelease: boolean;
  assets: Asset[];
};

let inflight: Promise<Release[]> | null = null;
let repoInflight: Promise<{ stargazers_count: number } | null> | null = null;

export function getReleases(): Promise<Release[]> {
  if (!inflight) {
    inflight = fetch(LIST)
      .then((r) => (r.ok ? r.json() : Promise.reject(new Error(String(r.status)))))
      .then((rs: Release[]) => (Array.isArray(rs) ? rs.filter((r) => !r.draft) : []));
  }
  return inflight;
}

/** Star count for the nav button. Separate endpoint, still only fetched once. */
export function getRepoMeta(): Promise<{ stargazers_count: number } | null> {
  if (!repoInflight) {
    repoInflight = fetch(REPO_API)
      .then((r) => (r.ok ? r.json() : null))
      .catch(() => null);
  }
  return repoInflight;
}

/** Newest published release — the one the download links should point at. */
export function newest(releases: Release[]): Release | undefined {
  return releases.find((r) => !r.prerelease) ?? releases[0];
}

/** 987 · 4.2k · 31k — a badge, not an accountancy report. */
export function formatCount(n: number): string {
  if (n < 1000) return String(n);
  const k = n / 1000;
  return `${k >= 10 ? Math.round(k) : k.toFixed(1).replace(/\.0$/, "")}k`;
}

/** 84 MB. Worth showing next to a file: it is the difference between "later"
 *  and "now" on a phone or a metered connection. */
export function formatBytes(n: number): string {
  const mb = n / (1024 * 1024);
  if (mb < 1) return `${Math.max(1, Math.round(n / 1024))} KB`;
  return `${mb < 10 ? mb.toFixed(1) : Math.round(mb)} MB`;
}

// ── Platforms ────────────────────────────────────────────────────────────────
// One table, used by the download grid, the download menus in the hero and the
// nav, and the thanks page. They used to disagree about which file was which,
// which is how a tile labelled "Chrome · Firefox" ended up serving the Chrome
// zip to everyone.

export type OsId = "mac" | "linux" | "windows" | "chrome" | "firefox";

/** One downloadable file. The download section lists all of them; the menus
 *  only ever offer the platform's primary. */
export type FileOption = { label: string; hint: string; needles: string[] };

export type Platform = {
  id: OsId;
  icon: string;
  title: string;
  meta: string;
  /** Short label for the menus — "macOS", not "macOS · Apple silicon". */
  short: string;
  /** Substrings that must ALL appear in an asset name. Ordered: first hit wins,
   *  so a .dmg beats the .app.zip. */
  match: string[][];
  /** Every format this platform ships, in the order a newcomer should try them. */
  files: FileOption[];
  /** Every asset this platform has ever shipped, for the download count. */
  counts: RegExp;
  /** What to do with the file once it lands — shown on the thanks page. */
  next: string[];
};

export const PLATFORMS: Platform[] = [
  {
    id: "mac",
    icon: "🍎",
    title: "macOS",
    short: "macOS",
    meta: "Apple silicon · .dmg",
    match: [[".dmg"], ["macos", ".zip"]],
    files: [
      { label: ".dmg", hint: "installer", needles: [".dmg"] },
      { label: ".app.zip", hint: "portable app", needles: ["macos", ".app.zip"] },
      { label: ".tar.gz", hint: "binary only", needles: ["macos", ".tar.gz"] },
    ],
    counts: /macos|\.dmg/,
    next: [
      "Open the .dmg and drag Opal to Applications.",
      "macOS may call it “damaged” — it is not notarized. Run `sudo xattr -cr /Applications/Opal.app` once, or use the install script, which skips that dialog.",
    ],
  },
  {
    id: "linux",
    icon: "🐧",
    title: "Linux",
    short: "Linux",
    meta: "AppImage · .deb · .rpm",
    match: [[".appimage"]],
    files: [
      { label: "AppImage", hint: "runs anywhere", needles: [".appimage"] },
      { label: ".deb", hint: "Debian · Ubuntu", needles: [".deb"] },
      { label: ".rpm", hint: "Fedora · RHEL", needles: [".rpm"] },
      { label: ".tar.gz", hint: "binary only", needles: ["linux", ".tar.gz"] },
    ],
    counts: /linux|\.appimage|\.deb|\.rpm/,
    next: [
      "Make it executable: `chmod +x Opal-*.AppImage`, then run it.",
      "Wayland needs `SDL_VIDEODRIVER=wayland`; the .deb and .rpm are on the releases page if you prefer a package.",
    ],
  },
  {
    id: "windows",
    icon: "🪟",
    title: "Windows",
    short: "Windows",
    meta: ".msi · alpha",
    match: [[".msi"]],
    files: [
      { label: ".msi", hint: "installer", needles: [".msi"] },
      { label: ".zip", hint: "portable", needles: ["windows", ".zip"] },
    ],
    counts: /windows|\.msi/,
    next: [
      "Run the .msi. SmartScreen will warn — the installer is unsigned.",
      "Windows is alpha: playback and search work, some services are still rough.",
    ],
  },
  {
    id: "chrome",
    icon: "🧩",
    title: "Opal Connect",
    short: "Extension (Chrome · Edge)",
    meta: "Chrome · Edge",
    match: [["opal-connect", "chrome"]],
    files: [{ label: "chrome.zip", hint: "load unpacked", needles: ["opal-connect", "chrome"] }],
    counts: /opal-connect.*chrome/,
    next: [
      "Unzip it, open `chrome://extensions`, turn on Developer mode, then “Load unpacked”.",
      "Opal has to be running — the extension talks to it on port 41595.",
    ],
  },
  {
    id: "firefox",
    icon: "🦊",
    title: "Opal Connect",
    short: "Extension (Firefox)",
    meta: "Firefox",
    match: [["opal-connect", "firefox"]],
    files: [{ label: "firefox.zip", hint: "temporary add-on", needles: ["opal-connect", "firefox"] }],
    counts: /opal-connect.*firefox/,
    next: [
      "Open `about:debugging` › This Firefox › Load Temporary Add-on, and pick the zip.",
      "Opal has to be running — the extension talks to it on port 41595.",
    ],
  },
];

export function platform(id: string | null): Platform | undefined {
  return PLATFORMS.find((p) => p.id === id);
}

/** The newest release's asset for a platform, or null if none matches. */
export function assetFor(releases: Release[], p: Platform): string | null {
  const assets = newest(releases)?.assets ?? [];
  for (const needles of p.match) {
    const hit = assets.find((a) => needles.every((n) => a.name.toLowerCase().includes(n)));
    if (hit) return hit.browser_download_url;
  }
  return null;
}

/** The newest release's asset matching one file option, with its size. */
export function fileFor(releases: Release[], f: FileOption): Asset | null {
  const assets = newest(releases)?.assets ?? [];
  return assets.find((a) => f.needles.every((n) => a.name.toLowerCase().includes(n))) ?? null;
}

/** A named asset from the newest release — SHA256SUMS.txt, say. */
export function namedAsset(releases: Release[], needle: string): Asset | null {
  const assets = newest(releases)?.assets ?? [];
  return assets.find((a) => a.name.toLowerCase().includes(needle)) ?? null;
}

/** Downloads to date for a platform, summed across every release. */
export function countFor(releases: Release[], p: Platform): number {
  return releases
    .flatMap((r) => r.assets ?? [])
    .filter((a) => p.counts.test(a.name.toLowerCase()))
    .reduce((n, a) => n + (a.download_count || 0), 0);
}

/** The visitor's platform, so the button can name it. */
export function detectOs(): OsId | null {
  if (typeof navigator === "undefined") return null;
  const ua = navigator.userAgent;
  if (/Mac/i.test(ua)) return "mac";
  if (/Win/i.test(ua)) return "windows";
  if (/Linux|X11|Android|CrOS/i.test(ua)) return "linux";
  return null;
}

/**
 * Send the browser to the file, then to the thank-you page.
 *
 * The anchor keeps a real asset URL in its href — people copy those, and it has
 * to survive JavaScript being off. The click handler lets the download start and
 * only then navigates, so the page change never cancels the transfer.
 */
export function startDownload(e: { preventDefault: () => void }, href: string, os: OsId) {
  if (!href) return; // no resolved asset: let the href (the releases page) win
  e.preventDefault();
  const a = document.createElement("a");
  a.href = href;
  a.download = "";
  document.body.appendChild(a);
  a.click();
  a.remove();
  setTimeout(() => {
    window.location.href = `/thanks?os=${os}`;
  }, 700);
}
