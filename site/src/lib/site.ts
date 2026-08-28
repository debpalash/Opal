export const SITE_URL = "https://opal.palash.dev";
export const SITE_NAME = "Opal Media Player";
export const REPO = "https://github.com/debpalash/Opal";
export const AUTHOR_URL = "https://x.com/idebpalash";
export const SOCIAL_IMAGE = "/assets/social-preview.png";

export type SitePage = {
  path: string;
  title: string;
  description: string;
};

// The single source of truth for canonical, indexable pages. sitemap.xml.ts
// consumes this list, and the SEO build check proves every entry exists.
export const SITE_PAGES: SitePage[] = [
  {
    path: "/",
    title: "Opal Media Player — Search, Stream & Play Everything",
    description:
      "Opal is a free, open-source media player for movies, TV, anime, live TV, YouTube, torrents, manga, Jellyfin and Plex—with local AI and no telemetry.",
  },
  {
    path: "/features/",
    title: "Opal Features — Universal Media Search & Streaming",
    description:
      "Explore Opal's universal search, torrent streaming, Jellyfin and Plex playback, live TV, manga, subtitles, local AI, watch parties and browser UI.",
  },
  {
    path: "/guides/keyless-movies-tv/",
    title: "Browse Movies & TV Without a TMDB Key in Opal",
    description:
      "Use Opal 0.6.6 to browse, search and open TV seasons and episodes through Cinemeta without configuring a TMDB catalog key.",
  },
  {
    path: "/compare/",
    title: "Opal vs Jellyfin, Plex, Stremio, Kodi & qBittorrent",
    description:
      "Compare Opal with Jellyfin, Plex, Stremio, Kodi and qBittorrent for universal search, torrent streaming, live TV, manga, local AI and privacy.",
  },
  {
    path: "/compare/jellyfin/",
    title: "Opal vs Jellyfin — Client and Server, Compared",
    description:
      "Jellyfin serves a library you host; Opal plays it alongside torrents, live TV, anime, YouTube and manga. When to run one, the other, or both.",
  },
  {
    path: "/compare/plex/",
    title: "Opal vs Plex — A Free, Local-First Alternative",
    description:
      "Plex is a polished proprietary media server tied to an account. Opal is a GPL-3.0 player that reads your Plex library with no account of its own.",
  },
  {
    path: "/compare/stremio/",
    title: "Opal vs Stremio — Streaming Without Add-on Roulette",
    description:
      "Stremio aggregates streams through add-ons; Opal builds torrent playback, live TV, manga and a local AI into one GPL-3.0 binary. Compare them here.",
  },
  {
    path: "/compare/kodi/",
    title: "Opal vs Kodi — One App Instead of an Add-on Stack",
    description:
      "Kodi is an endlessly extensible home-theater shell; Opal ships search, torrents, live TV, manga and local AI working out of the box. Compare the two.",
  },
  {
    path: "/compare/qbittorrent/",
    title: "Opal vs qBittorrent — Stream Torrents Instead of Waiting",
    description:
      "qBittorrent manages downloads; Opal treats a magnet as playable media and streams it while it downloads. See which fits, or why many keep both.",
  },
  {
    path: "/changelog/",
    title: "Opal Changelog — Release Notes & Version History",
    description:
      "Every Opal release in order, in the terms a user would notice: new features, fixes and platform changes across Linux, macOS and Windows builds.",
  },
  {
    path: "/extension/",
    title: "Opal Connect Extension — Chrome, Edge & Firefox",
    description:
      "Use Opal Connect to send media from Chrome, Edge or Firefox to Opal, add compatible sites as sources, search your media and control playback.",
  },
  {
    path: "/download/",
    title: "Download Opal for Linux, macOS & Windows",
    description:
      "Download the free Opal media player for Linux, macOS and Windows. Get verified AppImage, DEB, RPM, DMG, MSI and portable release files.",
  },
  {
    path: "/faq/",
    title: "Opal Media Player FAQ — Torrents, Plex, Jellyfin & More",
    description:
      "Answers about Opal's torrent streaming, Jellyfin and Plex support, local AI, browser extension, privacy, supported platforms and installation.",
  },
  {
    path: "/privacy/",
    title: "Opal Privacy — Local-First Media Player With No Telemetry",
    description:
      "Learn what Opal stores locally, when it connects to third-party media services, how plugins work and why the app needs no account or telemetry.",
  },
];

export function absoluteUrl(path: string): string {
  return new URL(path, SITE_URL).href;
}

export function pageFor(path: string): SitePage {
  const page = SITE_PAGES.find((candidate) => candidate.path === path);
  if (!page) throw new Error(`Missing SEO metadata for ${path}`);
  return page;
}

export function breadcrumbSchema(name: string, path: string, parent?: { name: string; path: string }) {
  const trail = [
    { name: "Opal", path: "/" },
    ...(parent ? [parent] : []),
    { name, path },
  ];
  return {
    "@type": "BreadcrumbList",
    itemListElement: trail.map((crumb, index) => ({
      "@type": "ListItem",
      position: index + 1,
      name: crumb.name,
      item: absoluteUrl(crumb.path),
    })),
  };
}
