/**
 * One entry per head-to-head page under /compare/. The copy is deliberately
 * honest about what the other app does better — these pages rank (and get
 * linked) because they read like advice, not advertising, and half the answer
 * to "Opal vs Jellyfin" really is "run both".
 */

export type Rival = {
  slug: string;
  name: string;
  lead: string;
  /** [capability, Opal, rival] */
  rows: [string, string, string][];
  chooseOpal: string[];
  chooseRival: string[];
  /** The one-paragraph verdict, plain HTML allowed. */
  verdict: string;
};

export const RIVALS: Rival[] = [
  {
    slug: "jellyfin",
    name: "Jellyfin",
    lead: "Jellyfin serves a library you host. Opal plays that library — alongside every other source you use. Many people run both.",
    rows: [
      ["What it is", "A player for every source", "A media server you host"],
      ["One search across sources", "Yes", "Its own library"],
      ["Play a torrent while it downloads", "Yes", "—"],
      ["Live TV", "Large IPTV catalog", "Tuner or M3U"],
      ["Manga and anime sources", "Yes", "—"],
      ["On-device AI copilot", "Yes", "—"],
      ["Server required", "No", "Yes"],
      ["Serves other devices", "LAN web UI", "Yes, its core job"],
      ["License", "GPL-3.0", "GPL-2.0"],
    ],
    chooseOpal: [
      "You want one search across Jellyfin, torrents, live TV, YouTube, anime and manga.",
      "You don't want to set up or maintain a server.",
      "You want magnets to play like files and an AI copilot that stays on your machine.",
    ],
    chooseRival: [
      "You're hosting a curated library that several people and devices stream from.",
      "You need user accounts, parental controls and per-user watch state.",
      "You want a server-side transcoding pipeline tuned for remote streaming.",
    ],
    verdict:
      "They're complements, not substitutes. Jellyfin is the best free way to serve a library you own; Opal signs into that server and adds everything a server doesn't do — torrents, live TV, manga, a local AI. If you already run Jellyfin, keep it and point Opal at it.",
  },
  {
    slug: "plex",
    name: "Plex",
    lead: "Plex is polished, proprietary and account-first. Opal is open source, local-first — and happy to play your Plex library.",
    rows: [
      ["What it is", "A player for every source", "A media server + streaming service"],
      ["One search across sources", "Yes", "Its own library"],
      ["Play a torrent while it downloads", "Yes", "—"],
      ["Live TV", "Large IPTV catalog", "Tuner, plus its own FAST channels"],
      ["Manga and anime sources", "Yes", "—"],
      ["On-device AI copilot", "Yes", "—"],
      ["Account required", "No", "Plex account"],
      ["Remote streaming", "LAN web UI", "Yes, with a paid tier"],
      ["License", "GPL-3.0", "Proprietary"],
    ],
    chooseOpal: [
      "You want your media life out of a cloud account and in a local SQLite file.",
      "You want torrents, IPTV, anime, YouTube and manga next to your Plex library.",
      "You'd rather not have features move behind a Plex Pass.",
    ],
    chooseRival: [
      "You stream your library remotely to family on TVs, phones and consoles.",
      "You want a managed, no-thought experience and don't mind the account.",
      "You use Plex's own content — its FAST channels and rentals.",
    ],
    verdict:
      "Plex's server and apps are genuinely slick, and for streaming to a household of devices it's still the path of least resistance. Opal connects to a Plex server as a client, so the real question is what you sign into every day: a proprietary account in the cloud, or a GPL app whose history lives on your disk.",
  },
  {
    slug: "stremio",
    name: "Stremio",
    lead: "Both put many sources behind one search box. Stremio does it with add-ons and an account; Opal does it natively, in one binary.",
    rows: [
      ["What it is", "A player for every source", "A streaming aggregator"],
      ["How sources work", "Built in, plus plugins", "Community add-ons"],
      ["Play a torrent while it downloads", "Yes", "Yes"],
      ["Jellyfin and Plex libraries", "Both", "Add-ons"],
      ["Live TV", "Large IPTV catalog", "Add-ons"],
      ["Manga", "Yes", "—"],
      ["On-device AI copilot", "Yes", "—"],
      ["Account", "None", "Account to sync"],
      ["License", "GPL-3.0", "Partly open — the streaming server is closed"],
    ],
    chooseOpal: [
      "You want torrent streaming, live TV and manga maintained in the app, not by add-on authors.",
      "You want to skip the account and keep watch history in a local file.",
      "You care that the whole stack — including the streaming engine — is GPL-3.0.",
    ],
    chooseRival: [
      "You live inside its add-on catalog and the community picks for you.",
      "You want first-party mobile and TV apps today.",
      "Cross-device sync through an account is a feature for you, not a cost.",
    ],
    verdict:
      "Stremio's add-on ecosystem is huge and its TV apps are ahead of Opal's. But its streaming server ships as a closed binary and everything routes through an account. Opal makes the opposite trade: fewer platforms so far, and a fully open, local-first stack where the core sources are built in.",
  },
  {
    slug: "kodi",
    name: "Kodi",
    lead: "Kodi can be built into almost anything, one add-on at a time. Opal ships assembled.",
    rows: [
      ["What it is", "A player for every source", "A home-theater platform"],
      ["Works out of the box", "Yes", "A shell you extend"],
      ["One search across sources", "Yes", "Add-ons"],
      ["Play a torrent while it downloads", "Yes", "Add-ons"],
      ["Live TV", "Large IPTV catalog", "PVR back-ends and add-ons"],
      ["Manga", "Yes", "—"],
      ["On-device AI copilot", "Yes", "—"],
      ["10-foot / TV interface", "Desktop-first", "Yes, its home ground"],
      ["License", "GPL-3.0", "GPL-2.0+"],
    ],
    chooseOpal: [
      "You want cross-source search, torrent streaming and live TV working on first launch.",
      "You'd rather not maintain a stack of add-ons that break independently.",
      "You read manga and want it beside your video sources.",
    ],
    chooseRival: [
      "You're building a living-room box driven by a remote from the couch.",
      "You want deep skinning and add-ons for practically everything.",
      "You need platforms Opal doesn't reach — Android boxes, smart-TV hardware.",
    ],
    verdict:
      "Kodi's superpower is that it can become anything; the cost is that you assemble it, and every add-on is a separate maintainer. Opal covers the common case — search, play, torrents, live TV, manga — with parts that ship and update together. For a TV-remote setup, Kodi is still the better home.",
  },
  {
    slug: "qbittorrent",
    name: "qBittorrent",
    lead: "qBittorrent downloads torrents. Opal plays them — starting while the pieces are still arriving.",
    rows: [
      ["What it is", "A player for every source", "A BitTorrent client"],
      ["Play while downloading", "Yes", "Download first"],
      ["Built-in torrent search", "Yes, ranked with other sources", "Yes, via search plugins"],
      ["Everything that isn't torrents", "Jellyfin, Plex, live TV, YouTube, anime, manga", "—"],
      ["Seeding and ratio management", "Basic", "Extensive"],
      ["RSS automation", "Feed reader with magnet routing", "Full rules engine"],
      ["Per-torrent controls", "Priorities, limits, piece map", "Everything, per tracker"],
      ["License", "GPL-3.0", "GPL-2.0+"],
    ],
    chooseOpal: [
      "You open a magnet to watch it, not to manage it.",
      "You want torrent results ranked next to your servers and web sources.",
      "You want subtitles, resume and watch history around torrent playback.",
    ],
    chooseRival: [
      "You seed long-term and care about ratios, trackers and queueing discipline.",
      "You automate downloads with RSS rules.",
      "You need fine-grained control a dedicated client is built for.",
    ],
    verdict:
      "Different jobs. qBittorrent is a precision tool for the download itself; Opal is for the two hours after you press play. If you seed seriously, keep qBittorrent for management and let Opal be the thing that actually plays the file.",
  },
];

export function rivalFor(slug: string): Rival {
  const rival = RIVALS.find((candidate) => candidate.slug === slug);
  if (!rival) throw new Error(`Unknown comparison: ${slug}`);
  return rival;
}
