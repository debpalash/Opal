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

## More tools: when to use which

- **"What should I watch?"** `home_summary` first (counts and what to continue), then `library_list` or `calendar_list` for detail.
- **Tracks and sync.** `player_info` lists audio and subtitle track ids and the current delay. Switch with `player_audio_track` / `player_subtitle_track` (an id or `off`); fix out-of-sync subtitles with `subtitles_delay` (seconds, positive shows them later).
- **Cast to a TV.** `cast_scan`, wait a few seconds, `cast_devices`, then `cast_start` with the device position while something is playing. `cast_stop` ends it. It needs `catt` installed; say so if the scan finds nothing.
- **Torrents.** `downloads_list` is direct downloads; `torrents_list` is live torrents. `torrent_files` shows what a pack has so far. `torrent_pause` / `torrent_resume` are safe; `torrent_cancel` is destructive. `download_history_*` only edits the list of past downloads, never files.
- **Jellyfin.** If `jellyfin_results` says `connected: false`, tell the user to sign in in the app (you cannot). Otherwise `jellyfin_libraries` or `jellyfin_search`, wait, read `jellyfin_results` again, then `jellyfin_browse` into a folder or `jellyfin_play` an item id. Prefer plain `search` when the user does not care where it comes from.
- **Feeds.** `rss_add` (http(s) URL), `rss_refresh`, `rss_list`. `rss_remove` is destructive. Do not repeat a feed URL that looks like it carries a key back to the user.
- Anything that says "read X a moment later" starts a background load: call the matching results tool again until it fills in. `history_list` is search history, not what was watched.

## Wanted list (automation)

When the user wants something that is not out yet or should just arrive on its own, `wanted_add` it instead of searching by hand: a movie by `title` and `year`, an episode by `title`, `season`, `episode`. Opal searches, picks the best release by quality and seeders, downloads it and marks it fulfilled. Check progress with `wanted_list` (`status`, `attempts`, `picked`); `wanted_check` forces a search now. Use `wanted_pause` / `wanted_remove` to stop. Do not add duplicates; list first.

## Extending Opal with a plugin

To add a source Opal does not have, `plugin_scaffold` an id, then edit `<config>/plugins/<id>/search` (a Lua script: the query is `arg[1]`; print a JSON array of rows with `id` or `stream_url`, plus optional `title`, `year`, `type`, `poster`, `overview`, `episodes`). It will not run until the user approves it in Settings → Plugins, and you cannot approve it: say so and wait. Once approved, `plugin_test` shows the outcome and the rows; fix `malformed` or `run_failed` and test again. Editing the script after approval revokes it. The Lua sandbox has no `io`, `os` or `require`, so fetch nothing and read nothing from disk; a plugin that needs the network must be a native executable, which gets the same review.

## Scheduled agent tasks

`agent_task_add` saves a prompt a coding agent runs unattended on a timer (`interval_min`, 15 to 10080; `max_runs_per_day` caps cost). Use it for chores the user wants repeated, such as "each morning check the wanted list and report what is stuck". Write the prompt so it works with nobody to answer questions. Nothing runs until the user turns on **Settings → Agent Access → Run scheduled agent tasks**; you cannot turn it on, so tell the user when a task is waiting for it (`agent_tasks_list` shows `enabled`, `last_outcome` and a one-line `last_summary`). `agent_task_run` runs one on the next tick and counts toward its cap. Do not schedule a task that schedules more tasks.

## Rules

- Never pass a local file path to a URL tool; they accept only http(s) and magnet links.
- `queue_clear`, `downloads_cancel`, `torrent_cancel`, `rss_remove` and the `download_history_*` removals are destructive and off by default. Ask the user before asking them to enable it, and pass `confirm: true` only after they agree.
- If a tool says Opal is not reachable, tell the user to start Opal and enable Web Remote (loopback).
