# Catalog and TV responsiveness

The Movies/TV catalog now overlaps Cinemeta movie and series requests. Season
changes reuse the most recently loaded Cinemeta series document for up to 12
minutes, avoiding a second download of the same full episode list. The cache
holds only one show and is freed at shutdown.

Filter changes during a catalog request are coalesced into the newest selection;
obsolete pages are discarded before publication. Returning from Search to
Trending fetches the selected browse feed. TV's On Air and Upcoming filters use
TV endpoints instead of movie theatrical lists. Catalog and episode parsers
accept whitespace around JSON field separators.

Catalog poster workers write to eight stable staging slots and publish by card
identity on the UI thread. Replacing a page frees its artwork; saving a card to
a list copies metadata without sharing image ownership. Episode autoplay now
requires a full query match even when providers finish, leaving partial matches
for explicit selection.

## Additional sources

Install these in Plugins:

- **Internet Archive** searches items with BitTorrent bundles using the
  [Archive search API](https://archive.org/advancedsearch.php). It performs one
  bounded request and reports unknown seed counts honestly. A live Sintel
  search returned 26 torrent rows during verification; this is not a playback
  or swarm-availability guarantee.
- **bitmagnet (self-hosted)** uses the existing native Torznab integration.
  Set the base URL to your instance; the default is localhost port 3333 with
  `/torznab/api`. See the [bitmagnet integration guide](https://bitmagnet.io/guides/servarr-integration.html).

## Verification

```sh
zig build test
zig build test-browse test-tv-detail -Doptimize=ReleaseFast
python3 tests/test_features.py --database /tmp/opal-tests/opal.db --results /tmp/opal-tests/results.json
zig build -Doptimize=ReleaseFast
```

The native regression suite exercises production parsing, queued request replay,
poster replacement and saved-list ownership, concurrent movie/series dispatch,
and season switching from a published document without a network worker.
Provider uptime, device decoding performance and live stream startup remain
separate from these deterministic checks; no app-wide speed multiplier is claimed.
