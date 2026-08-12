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
    path: "/compare/",
    title: "Opal vs Jellyfin, Plex, Stremio, Kodi & qBittorrent",
    description:
      "Compare Opal with Jellyfin, Plex, Stremio, Kodi and qBittorrent for universal search, torrent streaming, live TV, manga, local AI and privacy.",
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

export function breadcrumbSchema(name: string, path: string) {
  return {
    "@type": "BreadcrumbList",
    itemListElement: [
      {
        "@type": "ListItem",
        position: 1,
        name: "Opal",
        item: absoluteUrl("/"),
      },
      {
        "@type": "ListItem",
        position: 2,
        name,
        item: absoluteUrl(path),
      },
    ],
  };
}
