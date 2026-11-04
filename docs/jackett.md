# Jackett in Opal

Open **Connect → Torrent indexers → Set up / start Jackett**. Opal downloads
Jackett's official self-contained binary (~50 MB), verifies the pinned release's
SHA-256, starts it on a loopback-only port and saves the API connection. No
separate Jackett installation, service or external browser is needed.

Use **Manage trackers in Opal** (the settings icon) to open Jackett's dashboard
inside Opal's Browser. Add, configure, test and remove trackers there, then
return to Connect and refresh. Public trackers participate in Opal's torrent
searches. Select all configured public trackers, or choose individual sources.
The Jackett card in Plugins also opens these controls.

Opal keeps Jackett's binaries and tracker configuration in
`<Opal config>/jackett-managed/`. Stopping Jackett or quitting Opal terminates
only Opal's managed process tree and preserves tracker accounts. A saved managed
connection starts again on the next Opal launch. Jackett's independent updater
is disabled; Opal pins the binary version and checksum. Binary upgrades currently
ship with Opal connector updates. Existing servers can also be connected through
the optional **Existing server** controls.

Account-required trackers remain visible in the connection catalog, but this
connector excludes them from streaming searches. Private trackers require a
persistent seeding backend with retained files, accurate tracker policy and
resume handling. Opal's RAM streaming cannot meet that requirement. Jackett
handles discovery and authentication; it does not seed torrents. TorrentLeech
support therefore remains pending that backend.

Supported managed binaries: macOS Apple Silicon/Intel, Linux glibc x86-64/ARM64,
and Windows x64. The managed runner uses Opal's existing Python 3 runtime.
Linux musl and other architectures need an existing Jackett server for now.
The official Mac ARM64 binary is exercised locally; other platform launches
still need platform testing.

This integration uses Jackett's API rather than copying its C#/Cardigann scraper
implementations. Jackett's bundled licenses remain in the downloaded archive.
See [Jackett's documentation](https://github.com/Jackett/Jackett#api-usage).
