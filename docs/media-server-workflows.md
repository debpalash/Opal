# Personal-server workflow validation

The retained fixture suite runs actual Opal APIs against isolated Jellyfin/Plex
protocol fixtures. It generates a 120-second MPEG-4 Part 2/AAC Matroska file with an
embedded English subtitle using FFmpeg; it uses no copyrighted media, real
server credentials, user profile, or running user app.

```sh
python3 tests/test_media_servers_live.py --binary /path/to/opal --port 41811
node --test tests/test_web_lifecycle.mjs
```

## Verified workflow

| Provider | Actual app coverage |
| --- | --- |
| Jellyfin | Username/password login; library and item browsing; authenticated direct play of the preferred media source; server resume around 30 seconds; subtitle off/on; seek and pause; session progress POST; persisted local resume around 60 seconds; HTTP 401 clears the connection; fresh login and a new authenticated stream resume playback. A delayed login cannot restore a deliberately disconnected account. |
| Plex | Production saved-server restore; sections and item browsing; authenticated part direct play; server resume around 30 seconds; subtitle off/on; seek and pause; timeline POST; persisted local resume around 60 seconds; HTTP 401 clears the session; an isolated restart with rotated saved credentials opens a fresh stream and resumes. Copied section keys preserve the chosen library when the server reorders its sections. |

Both `/api/status` and `/api/player` retain the provider's catalog title.
The rich player snapshot remains valid JSON through subtitle discovery and
output-device fields. Media authentication is sent in headers, and persisted
watch-history links contain no authentication token. Native library chips and
web library actions use the same stable section-key service action; numeric
Plex section indexes remain available for older API callers.

## Reproductions fixed

- Plex's empty-body progress POST reached an assertive bodyless HTTP path and
  crashed the app. The shared native transport now sends an empty POST body.
- Subtitle discovery closed the outer player JSON object too early.
- A successful delayed Jellyfin login could undo Disconnect. Authentication now
  owns its cancellation generation and checks it under the publication mutex.
- Plex's rendered section index could open another library after a refresh.
  Section requests now own the stable key, and section snapshots are copied
  under a module mutex before native/web drawing or serialization.
- The rich player API bypassed supplied catalog titles and exposed a stream
  filename. Its metadata preference now agrees with Now Playing.

## Limits

This proves the shared native playback engine and browser API actions, plus a
production web-renderer action regression. It does not prove rendered desktop
pixels or a browser video decoder. The media fixtures cover direct play and
embedded subtitles; external subtitle delivery, server transcoding, multipart
movies and uncommon codecs are separate scenarios. Plex cloud PIN/OAuth and
real remote servers are not contacted; reconnect uses production saved-server
restore with newly seeded, isolated credentials. Real deployments can impose
other permissions, TLS, codec or network restrictions.
