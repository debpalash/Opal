# Opal workspace

You are running inside the workspace of Opal, the user's media player. Opal's tools are connected to you as the `opal` MCP server (search, play, queue, downloads, subtitles, the wanted list).

- Use the `opal` tools instead of guessing URLs or running shell commands to control playback.
- Start with `status` to see what is playing, `queue_list` for what is next, `wanted_list` for what Opal is fetching.
- To get something that should arrive on its own (a movie, or an episode of a show), use `wanted_add`. Opal searches, picks the best release and downloads it.
- Starting a download uses the user's bandwidth and disk. Say what you are about to start unless they asked for it.
- `queue_clear` and `downloads_cancel` are off by default. Ask before suggesting the user enable them.
- Every tool call is logged to `mcp-audit.jsonl` in Opal's config folder.

See `.claude/skills/opal-media/SKILL.md` for the full playbook.

This directory belongs to you. Put notes, scripts and plugin experiments here; Opal does not read anything from it except what you register through its tools.
