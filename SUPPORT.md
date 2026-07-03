# Getting help with Opal

**Before filing anything**, two minutes of triage:

1. Update to the latest release — `git pull && zig build run` or grab the
   newest artifact from Releases.
2. Check the in-app **Logs** tab (`Logs & Plugins` in the top bar). Most
   "nothing happens" reports are a missing native dependency or a source that's
   offline, and the log line says so.
3. Search existing [issues](../../issues) — including closed ones.

## Where to ask

| You want… | Go to |
|---|---|
| "How do I…?" / setup help / general chat | [GitHub Discussions](../../discussions) |
| A reproducible bug | [Bug report](../../issues/new?template=bug_report.yml) |
| A feature | [Feature request](../../issues/new?template=feature_request.yml) |
| To report a security vulnerability | [`SECURITY.md`](SECURITY.md) — **not** a public issue |
| A copyright/takedown matter | [`DMCA.md`](DMCA.md) |

## What a good bug report includes

- **Platform + versions**: OS, `zig version`, `mpv --version`, and whether you
  run a release artifact or a source build.
- **What you did, what happened, what you expected** — three sentences beat
  three paragraphs.
- **Logs**: the relevant lines from the in-app Logs tab, and for crashes on
  macOS the newest `opal-*.ips` from `~/Library/Logs/DiagnosticReports/`.
- Whether `just test-all` passes on your machine (`fail` count and names).

## Supporting the project

Opal is built by volunteers. Stars, sponsorships, and pull requests all
genuinely help — see the *Support the project* section in the README.
