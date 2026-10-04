---
name: opal-media
description: Find, play, queue and download media with the user's Opal player through the opal MCP server. Use when the user asks to watch, play, find, queue, pause, skip or download a movie, show, anime, video, song or stream.
---

# Operating Opal

Opal is the user's media player. Use the `opal` MCP tools instead of guessing URLs or shelling out.

## Watch something

1. `search` with a plain title. It returns immediately and results fill in over a few seconds.
2. `search_results`, repeated every couple of seconds, until `loading` is `false`. Note the top-level `generation`.
3. Choose a result: prefer `playable: true`, a matching `title`/`year`, and for torrents healthy `seeds`. `verified_work_match` and `work_representative` mark the best offer for a work.
4. `search_play` with that `generation` and the result's `key` (or `search_queue` to add it to the queue).
5. `status` to confirm it is playing. If `error` is set and `retryable` is true, try the next result.

A `409` or "stale" error means a newer search replaced the results; search again.

## Control playback

`player_toggle` pauses or resumes. `player_seek` takes absolute seconds, so read `pos` and `dur` from `status` first. `player_next` / `player_previous` move through the queue. For subtitles call `subtitles_search`, then `subtitles_download` with an index.

## Downloads

`downloads_list` gives each item an `idx` and `token`; pass both to `downloads_pause` / `downloads_resume`. Starting a download (`downloads_add_url`, or `play_url` with a magnet) uses bandwidth and disk, so say what you are about to start when the user did not ask for a download explicitly.

## Wanted list (automation)

When the user wants something that is not out yet or should just arrive on its own, `wanted_add` it instead of searching by hand: a movie by `title` and `year`, an episode by `title`, `season`, `episode`. Opal searches, picks the best release by quality and seeders, downloads it and marks it fulfilled. Check progress with `wanted_list` (`status`, `attempts`, `picked`); `wanted_check` forces a search now. Use `wanted_pause` / `wanted_remove` to stop. Do not add duplicates; list first.

## Rules

- Never pass a local file path to a URL tool; they accept only http(s) and magnet links.
- `queue_clear` and `downloads_cancel` are destructive and off by default. Ask the user before asking them to enable it, and pass `confirm: true` only after they agree.
- If a tool says Opal is not reachable, tell the user to start Opal and enable Web Remote (loopback).
