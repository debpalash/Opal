# Distribution & Launch Playbook

The map from "v0.1.0 exists" to "people actually find it." Everything here is
a checkbox because distribution is a queue, not a mood. Work top to bottom;
each section is honest about its prerequisites, and several of them have a
hard dependency you can't checklist your way around: **the repo must be
public first.**

Rules of engagement:

- One submission per venue, hand-written, after reading that venue's
  contributing rules. No batching, no automation (see
  [the anti-spam note](#what-we-will-not-do) at the bottom).
- Always disclose that you're the author. Every community can smell
  astroturf; none of them can smell honesty coming.
- Don't submit anything that points at a 404. If the artifact isn't in a
  public release yet, the checkbox stays unchecked.

## 0. Preflight (blockers, not niceties)

- [ ] Flip the repo to **public**.
- [ ] Replace the `[INSERT DMCA CONTACT]` placeholder in
      `CONTENT_POLICY.md` — going public with a blank takedown contact is
      asking for the wrong kind of first issue.
- [ ] Confirm every artifact below is attached to the
      [v0.1.0 release](https://github.com/debpalash/Opal/releases) with a
      `SHA256SUMS` file alongside.
- [ ] Load the README logged-out: badges, screenshots, GIFs all render.

## 1. Now — artifacts in GitHub Releases

What ships today, and who each file is for:

- [ ] **macOS arm64 `.dmg`** — the double-click install for Apple Silicon;
      the artifact most humans want.
- [ ] **macOS `.app` (zipped)** — the same bundle without the dmg ceremony;
      for scripted installs and people who drag-and-drop on principle.
- [ ] **macOS arm64 tarball** — bare binary for Homebrew-style and CI
      consumption.
- [ ] **Linux `tar.gz`** — distro-agnostic binary drop; untar, run, done.
- [ ] **Linux `.deb`** — `dpkg -i` for Debian/Ubuntu/Mint people.
- [ ] **Linux `.rpm`** — the same courtesy for Fedora/openSUSE people.
- [ ] **Linux AppImage** — `chmod +x`, run, no install; the "just let me try
      it" format.
- [ ] **Linux `.run`** — self-extracting installer for everyone the above
      four somehow missed.
- [ ] **macOS Intel (best-effort)** — cross-compiled, not tested on real
      x86_64 hardware; label it as such in the release notes.

## 2. Package managers

### 2.1 Homebrew (macOS) — do first, it's nearly done

The formula already exists at [`Formula/opal.rb`](../Formula/opal.rb); it
just needs a public home.

- [ ] Create a **public** repo `debpalash/homebrew-tap`.
- [ ] Move `Formula/opal.rb` there (path: `Formula/opal.rb`). While you're
      in there, pin `url`/`tag` to `v0.1.0` and drop the `revision: "HEAD"`
      placeholder for a real commit SHA.
- [ ] Add the companion `apfel` formula the opal formula already references
      (`brew install debpalash/tap/apfel`), or soften that caveat.
- [ ] Test on a clean machine: `brew install debpalash/tap/opal`.
- [ ] Document in the README: `brew install debpalash/tap/opal`.

**Later milestone — homebrew-core.** Their notability bar (checked by
`brew audit --new`) is roughly ~75 GitHub stars, a 30-day-old repo, and real
usage; they also frown on authors submitting their own software before it's
demonstrably popular. Park this until the star count argues for itself, then
ideally let a user submit it.

### 2.2 AUR (Arch Linux)

The in-repo [`PKGBUILD`](../PKGBUILD) builds from the **local** working tree
— fine for `makepkg` on your own box, not publishable as-is.

- [ ] Adapt the PKGBUILD to fetch the release:
      `source=("$pkgname-$pkgver.tar.gz::https://github.com/debpalash/Opal/archive/refs/tags/v$pkgver.tar.gz")`
      with real `sha256sums`, and build in `"$srcdir/Opal-$pkgver"` instead
      of `$startdir`.
- [ ] Fix `makedepends`: it currently says `zig>=0.15.2`; the project
      requires **0.16.x**. Check whether Arch's `zig` package has caught up;
      if not, depend on `zig-bin` from AUR or vendor the toolchain fetch.
- [ ] Create an account at <https://aur.archlinux.org>, add your SSH public
      key under account settings.
- [ ] Claim the name: `git clone ssh://aur@aur.archlinux.org/opal.git`
      (cloning an empty repo reserves it on first push).
- [ ] Add `PKGBUILD`, generate metadata:
      `makepkg --printsrcinfo > .SRCINFO` (commit **both** files — the AUR
      rejects pushes without `.SRCINFO`).
- [ ] Test in a clean chroot (`extra-x86_64-build` from `devtools`), then
      `git push`.
- [ ] **`opal-bin` variant:** second AUR package sourcing the prebuilt Linux
      tarball from Releases — no `zig`/`gcc` makedepends, near-instant
      install, same runtime `depends`. Same clone/push dance against
      `ssh://aur@aur.archlinux.org/opal-bin.git`.

### 2.3 Debian / Ubuntu

**The honest version:** the official archive means finding a Debian
Developer sponsor via <https://mentors.debian.net>, filing an ITP bug, and
waiting months — plus a Zig 0.16 toolchain story Debian doesn't have yet.
That's a someday, not a now.

**The realistic path today:**

- [ ] Keep shipping the `.deb` in GitHub Releases (already in section 1).
- [ ] Optional: self-hosted apt repo on GitHub Pages so users get upgrades
      via `apt`. Sketch with `reprepro`:

      ```sh
      # once
      mkdir -p apt/conf && cat > apt/conf/distributions <<'EOF'
      Codename: stable
      Components: main
      Architectures: amd64
      SignWith: <your-gpg-key-id>
      EOF
      # per release
      reprepro -b apt includedeb stable opal_0.1.0_amd64.deb
      # publish apt/ on the gh-pages branch; users add:
      #   deb [signed-by=/usr/share/keyrings/opal.gpg] https://debpalash.github.io/Opal/apt stable main
      ```

      (`aptly` works identically if you prefer: `aptly repo create`,
      `aptly repo add`, `aptly publish repo`.)
- [ ] File the mentors.debian.net RFS only when someone actually volunteers
      to sponsor; link it from a `good-first-packaging` issue.

### 2.4 Fedora — COPR

- [ ] Create a Fedora account at <https://accounts.fedoraproject.org>, then
      sign in at <https://copr.fedorainfracloud.org>.
- [ ] Produce a `opal.spec` (reuse whatever generated the release `.rpm`) and
      build an SRPM: `rpmbuild -bs opal.spec`.
- [ ] Create the project and build:

      ```sh
      copr-cli create opal --chroot fedora-42-x86_64 --chroot fedora-41-x86_64
      copr-cli build opal opal-0.1.0-1.src.rpm
      ```

- [ ] Document for users: `dnf copr enable debpalash/opal && dnf install opal`.
- [ ] **Later milestone:** official Fedora needs a package review on
      Bugzilla and a sponsor for your first package — same energy as Debian,
      slightly faster queue.

### 2.5 AppImageHub

- [ ] Prerequisite: the AppImage is attached to a **public** release.
- [ ] Fork <https://github.com/AppImage/appimage.github.io>, add a
      `data/Opal` entry pointing at the repo/release per their template, open
      a PR.
- [ ] Their CI actually downloads and launches the AppImage headlessly — make
      sure it starts on a bare Ubuntu runner (no TMDB token, no models)
      without crashing before you submit.

### 2.6 Snap Store

Manifest scaffolding lives at
[`packaging/snapcraft.yaml`](../packaging/snapcraft.yaml) — read its header;
it is **untested** until someone runs `snapcraft` on Linux.

- [ ] Ubuntu One account → `snapcraft login`.
- [ ] `snapcraft register opal` (first come, first served; dispute via the
      snapcraft forum if squatted).
- [ ] Request **classic confinement** approval in the store-requests category
      on <https://forum.snapcraft.io> — the justification is written out in
      the manifest's comments (subprocess helpers + arbitrary media paths).
- [ ] On a Linux box with LXD: `cp packaging/snapcraft.yaml snap/snapcraft.yaml
      && snapcraft` (or `snapcraft remote-build` to borrow Launchpad's
      machines from macOS).
- [ ] `snapcraft upload opal_*.snap --release=edge`, soak, then promote:
      `snapcraft release opal <rev> stable`.

### 2.7 Flathub — milestone, not a weekend

The biggest Linux storefront and the biggest lift. A submission needs:

- An **app ID rooted in a domain you control**: `org.debpalash.Opal` only
  works if you own `debpalash.org`; otherwise Flathub's accepted form for
  GitHub-hosted projects is `io.github.debpalash.Opal`. Pick before the
  first release — IDs are forever.
- Runtime `org.freedesktop.Platform` (24.08), with **mpv, libtorrent-rasterbar,
  onnxruntime, and SDL2 as manifest modules** built from pinned sources
  (Flathub builds are offline — every download, including the Zig toolchain
  tarball, must be a declared source with a checksum).
- AppStream metainfo XML + desktop file + icon, with screenshots.
- [ ] When ready, follow <https://docs.flathub.org/docs/for-app-authors/submission>
      (PR against `flathub/flathub` with the manifest).

### 2.8 BSDs — invitation, not promise

No FreeBSD or OpenBSD builds exist and none have been attempted. Source
builds *may* work: the deps (mpv, sqlite, SDL2, libtorrent-rasterbar) are all
in ports; the wildcard is a **Zig 0.16.x** toolchain and our POSIX
assumptions being Linux/macOS-flavored.

- [ ] Add a `porting` issue label and a pinned issue inviting port
      maintainers, listing the dep matrix (Zig 0.16, libtorrent-rasterbar 2.x,
      libmpv, onnxruntime) and offering fast review for portability patches.

### 2.9 Windows — explicitly deferred

There is no Windows port, so there is nothing to put in scoop, winget,
chocolatey, or an MSI — and listing packages that install nothing is
vaporware with a manifest. The gap is not the dependencies (mpv, SDL2,
libtorrent, onnxruntime all have Windows builds); it's the platform layer:
`io_global` wraps POSIX process/path/time semantics, sidecars are spawned
Unix-style, the torrent wrapper is compiled by a `sh` build step, and the
whole runtime assumes XDG paths and a Unix PATH. A minimal port means a
win32 backend for `io_global`, a vcpkg/MSYS2 dependency story, replacing the
shell build steps, and a Windows CI runner — a real project, tracked in
`ROADMAP.md` if/when someone wants it. Until a binary exists, the honest
Windows section of the README is one sentence: "no Windows support yet."

## 3. Awesome lists & directories

**All of these wait until the repo is public.** One PR per list. Read each
list's `CONTRIBUTING.md` first — most have exact formatting rules and reject
PRs that batch multiple additions or skip the template. Ready-to-paste
entries below; adjust section placement to whatever the list's TOC calls it.

- [ ] **awesome-zig** — <https://github.com/zigcc/awesome-zig> (Applications
      section):

      ```
      - [Opal](https://github.com/debpalash/Opal) — Local-first media app: universal search, torrent streaming, and an on-device AI copilot, built on dvui + mpv.
      ```

- [ ] **awesome-zig (C-BJ)** — <https://github.com/C-BJ/awesome-zig>
      (separate list, separate PR; match its section style):

      ```
      * [Opal](https://github.com/debpalash/Opal) - Local-first media app with universal search, torrent streaming, and an on-device AI copilot (dvui + mpv).
      ```

- [ ] **awesome-selfhosted** — <https://github.com/awesome-selfhosted/awesome-selfhosted>
      — submissions go via YAML in the
      [awesome-selfhosted-data](https://github.com/awesome-selfhosted/awesome-selfhosted-data)
      repo, not the README. Their criteria are strict (actively maintained,
      project age minimums, working docs) and they periodically freeze new
      additions and purge stale entries — check the repo's current status
      before writing the PR. Be upfront that Opal is desktop-first with a
      self-hosted web remote/API, and pitch the Media Streaming section;
      expect a debate. Rendered entry:

      ```
      - [Opal](https://github.com/debpalash/Opal) - Local-first media app that finds, curates and plays media from your disk, Jellyfin and sources you configure, with a phone-friendly web remote and JSON API. `GPL-3.0` `Zig`
      ```

- [ ] **awesome-mac** — <https://github.com/jaywcjlove/awesome-mac> (Video
      section; keep their icon suffixes):

      ```
      * [Opal](https://github.com/debpalash/Opal) - Local-first media player that searches all your sources at once, streams torrents like files, and ships an on-device AI. [![Open-Source Software][OSS Icon]](https://github.com/debpalash/Opal) ![Freeware][Freeware Icon]
      ```

- [ ] **awesome-mpv** — <https://github.com/stax76/awesome-mpv> (front-ends
      / GUI section):

      ```
      - [Opal](https://github.com/debpalash/Opal) - Local-first media app built on libmpv: universal search, torrent streaming, on-device AI copilot, watch parties.
      ```

- [ ] **awesome-privacy** — <https://github.com/Lissy93/awesome-privacy>
      (media / entertainment category; their bar is genuine privacy posture,
      which Opal clears on the merits):

      ```
      - [Opal](https://github.com/debpalash/Opal) - Local-first media player and aggregator: no accounts, no telemetry, no cloud — history and AI memory live in a local SQLite file you own.
      ```

- [ ] **AlternativeTo** — <https://alternativeto.net> — not a PR; create the
      listing via "Add an application." Description from the README's first
      paragraph, 3-4 screenshots, license GPL-3.0, platforms macOS + Linux.
      Then suggest Opal as an alternative on the **Stremio, Plex, Infuse,
      and IINA** pages — those are the search queries that should find it.

- [ ] **Suggest more:** when users mention Opal somewhere with a directory
      (awesome-selfhosted alternatives, privacy wikis, r/FREEMEDIAHECKYEAH
      adjacent lists), let *them* file it — third-party submissions carry
      more weight everywhere.

## 4. Launch posts

Drafts below — edit for the news of the day, but keep the voice: specific,
unhyped, privacy-forward. Space the launches out (HN and Reddit on the same
morning splits your ability to answer comments, and answering comments *is*
the launch).

### 4.1 Show HN

- [ ] Title (73 chars, limit 80):

      > Show HN: Opal – local-first media app in Zig with an on-device AI copilot

- [ ] First comment, posted immediately after submitting (~150 words):

      > Hi HN — I built Opal because "watch something" at 11 PM had become
      > nine tabs: a player for files, a site for the show, an app for the
      > server, a wiki for "which episode was that." Opal's bet is that this
      > is one job: say what you're in the mood for — a title, a file, a
      > magnet, a vibe — and you're watching it.
      >
      > Stack: Zig 0.16, immediate-mode dvui UI, mpv for playback, libtorrent
      > with piece-prioritization so magnets play while they download, SQLite
      > + sqlite-vec for history and taste memory. The AI is a local LLM with
      > tool use — no API key, no bill. Whisper ears and Piper voice are
      > opt-in downloads.
      >
      > Privacy stance: no accounts, no telemetry, no cloud. Content sources
      > ship off — you install endpoints explicitly. GPL-3.0, macOS arm64
      > builds today, Linux packages landing. Happy to answer anything about
      > Zig, dvui, or shipping mpv + libtorrent in one binary.

### 4.2 r/selfhosted

- [ ] Title: **Opal — a local-first media app with a self-hosted web remote
      and JSON API (no accounts, no telemetry, GPL-3.0)**

      > Sharing something I built: Opal, a native media app (Zig + mpv) that
      > searches your disk, Jellyfin, torrents, and whatever sources you
      > configure — one ranked list, play button on every row. Magnets
      > stream like files via libtorrent piece-prioritization.
      >
      > The self-hosted angle: it runs a JSON API on :41595 and a
      > phone-friendly web remote on :3000, so it slots into your LAN like
      > any other service — but the "server" is just the app on the machine
      > by your TV. History and the AI's memory are a SQLite file in
      > ~/.config/opal that you own and can back up like anything else. The
      > AI is a local LLM — nothing phones home, verified by the fact that
      > there's nothing to phone home *to*.
      >
      > macOS arm64 builds are up; deb/rpm/AppImage are in the release.
      > Would love feedback from Jellyfin users especially.

### 4.3 r/DataHoarder

- [ ] Title: **I built a player where your hoard, your Jellyfin, and your
      torrents are one search box**

      > The problem: the hoard is on disk, the metadata is on a wiki, the
      > player is dumb, and "do I already have this?" takes three apps to
      > answer. Opal fans one query out across your filesystem, Jellyfin,
      > torrent indexers, and TMDB in parallel and returns one ranked,
      > playable list — so the answer to "do I have it?" and "press play"
      > is the same screen.
      >
      > Watch history, search history, and download history live in a plain
      > SQLite file (~/.config/opal/opal.db) — greppable, backupable, yours.
      > Subtitles come embedded, fetched, or Whisper-generated on the spot.
      > No accounts, no telemetry, GPL-3.0, macOS + Linux.

### 4.4 r/opensource

- [ ] Title: **Opal — GPL-3.0 media app in Zig: one binary for search,
      torrent streaming, playback, and a local AI**

      > Just took Opal public. It's a local-first media app written in Zig
      > 0.16 with an immediate-mode UI (dvui) and mpv underneath — the whole
      > system compiles to one native binary that exits with a receipt:
      > "Clean shutdown: 0 memory leaks."
      >
      > GPL-3.0 because it links libmpv and that's the honest choice. No
      > CLA. Contributions welcome — the test gate is one command
      > (`just test-all`) and CONTRIBUTING.md is short. Looking especially
      > for Linux packagers and BSD porters.

### 4.5 lobste.rs

- [ ] Submit the repo as a link with tags `zig`, `release` (lobste.rs is
      invite-only — if you lack an account, ask a Zig community member who
      has one; do not sockpuppet). Text field, if used, stays short:

      > Local-first media app in Zig 0.16: dvui immediate-mode UI, mpv
      > playback, libtorrent streaming, local LLM with tool use, one binary,
      > leak-checked shutdown. GPL-3.0.

### 4.6 ziggit.dev

- [ ] Title: **Opal: a media app in Zig 0.16 — dvui, mpv, libtorrent, and a
      threaded-Io shim**

      > I've been building a media player in Zig for a while and it's now
      > public. Things Zig folks might find interesting: a process-wide
      > threaded Io shim so 0.16's Io doesn't thread through every
      > signature; one global DebugAllocator with leak reporting on every
      > exit; fixed-size buffers in state structs instead of slice churn
      > (makes session save/restore trivial); a repaint-only-on-change dvui
      > loop; and a C++ ABI firewall for libtorrent behind a tiny wrapper
      > .so. Build is `zig build run` plus a handful of system libs.
      > Criticism of the 0.16 patterns very welcome — that's half the reason
      > I'm posting.

### 4.7 X / Bluesky

- [ ] Two-liner (fits both platforms):

      > Opal is public: one app that finds, curates, and plays whatever
      > you're in the mood for — with an AI that never leaves your machine.
      > Zig + mpv, no accounts, no telemetry, GPL-3.0.
      > https://github.com/debpalash/Opal

<a id="what-we-will-not-do"></a>

## 5. What we will not do

You will get emails offering to "submit Opal to 300+ directories" or blast
"backlink packages." Decline all of them. Automated submissions violate the
contributing rules of every list above (instant PR close, sometimes a ban),
the resulting link farms actively damage the domain's search reputation, and
bulk-submitted releases get flagged as spam on the platforms that matter.
The checklist above is slower and it is also the entire trick: real entries,
in the right sections, written by the author, one at a time. That's what
actually works — and it's free.

## One-command installer, updater, checksums

- [ ] `scripts/install.sh` is the official entry point (README leads with it):
      detects brew-tap / apt / dnf / zypper / AUR-helper / AppImage-fallback,
      verifies every download against the release's `SHA256SUMS.txt`, records
      an install receipt, and handles `update`, `uninstall`, `list-versions`,
      and `OPAL_VERSION=vX.Y.Z` pinning. Keep it working on plain `sh` (dash).
- [ ] `SHA256SUMS.txt` is generated by the publish job for every release
      (uploaded manually for v0.1.0 from the GitHub asset digests).
- [ ] Homebrew tap: run `packaging/homebrew-tap/push-tap.sh` after the repo is
      public — creates/updates `debpalash/homebrew-tap`; the installer prefers
      the tap automatically once it exists.
- [ ] In-app updater (`src/services/updater.zig`) polls
      `releases/latest` and matches the `.dmg` asset — bump its `APP_VERSION`
      whenever `build.zig.zon`'s version changes (it is 0.1.0 now).
