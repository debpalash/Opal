# Direct-stream plugins

Opal accepts direct HTTP(S) video and audio streams, including MP4 and HLS,
from user-installed executable plugins and Stremio add-ons. A provider that
returns a direct stream does not need the torrent engine or seeders.

## Try the example

Copy `examples/plugins/direct-stream` into the `plugins` directory inside your
Opal configuration directory. Edit `catalog.json` to point to media you control.
Review and approve the plugin in Settings > Plugins after editing; approval
is bound to the complete plugin contents, so edits require another review.
Python 3 must be available for this example.

For a local smoke test, serve your media with `python3 -m http.server 8000` from
the media directory. Search for **My video** in Opal, then choose an episode.
The example resolves an episode to its configured URL without contacting a
catalog service. Replace the local URLs before using it on another device.

## Protocol

The `search <query>` executable prints a JSON array:

```json
[{"id":"show-1","title":"My show","type":"video","episodes":2}]
```

The `resolve <id> <episode>` executable receives a one-based episode string and
prints one JSON object. Headers are optional:

```json
{
  "url":"https://media.example/episode-1.m3u8?signature=example",
  "quality":"1080p",
  "language":"en",
  "headers":{
    "Referer":"https://player.example/watch/1",
    "Origin":"https://player.example",
    "User-Agent":"MyPlayer/1.0"
  }
}
```

A search result can also carry `stream_url` plus the same headers, quality, and
language fields to play directly. Stremio `behaviorHints.proxyHeaders.request`
uses the same transport path. Parsed JSON preserves escaped characters and
field order does not matter. A valid SHA-1 `infoHash` becomes a torrent source.

URLs are accepted up to 8192 bytes and rejected above that limit; playback links
are never silently shortened. Referer and Origin share a 2048-byte prepared
header budget; User-Agent has a 512-byte budget. CR, LF, control characters,
and commas in these header values are rejected because mpv uses a
comma-separated header option. Only Referer, Origin, and User-Agent are
forwarded. Use one spelling for each header; do not repeat it in both the
`headers` object and the legacy top-level `referer`, `origin`, or `user_agent`
fields. Other request headers are currently ignored.

A resolver has a 30-second deadline. Exit nonzero on failure and put diagnostic
text on stderr. Do not print progress or secrets to stdout. Malformed output,
unsupported transports, and invalid headers produce a visible failure with
**Try again** and, when reached through Search, **Choose another source**.
New playback, cancellation, and closing a player invalidate earlier completions.

## Choosing sources

Search details show provider, stream type, and any supplied quality/language.
**Prefer provider** saves the provider identity for that title; canonical episode
queries for a show share the preference. It gives that provider a small ranking
boost and can be cleared. It never stores a signed stream URL as a preference.

**Choose another source** returns to the original search and preserves the
playback position when you select a replacement. **Try alternate sources
automatically** controls compatible URL fallbacks for the current player.
Header-bearing offers stay separate, so one provider's request identity is not
sent to another provider. Such streams and links above the queue's 2047-byte
limit have no Queue action; play them directly instead.

The browser companion controls desktop playback. A source requiring headers
plays through Opal's player; this does not grant a browser video element the
ability to set arbitrary request headers or bypass CORS.
