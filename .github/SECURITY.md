# Security Policy

Opal ("Play everything"; binary/config dir `opal`) is a native, local-first
desktop media runtime. It has undergone a security hardening pass, but it is
provided **as-is, with no warranty** of any kind. Please review the scope and
reporting guidance below before filing a report.

## Supported Versions

Security fixes are applied to the latest release and the `main` branch. Older
tagged releases are not maintained.

| Version            | Supported          |
| ------------------ | ------------------ |
| `main` (latest)    | :white_check_mark: |
| Latest release     | :white_check_mark: |
| Older releases     | :x:                |

## Reporting a Vulnerability

**Please do not open a public GitHub issue for security vulnerabilities.**

Report privately through either channel:

- **GitHub Private Advisory (preferred):** open a report via the repository's
  **Security → Report a vulnerability** tab
  (<https://github.com/debpalash/Opal/security/advisories/new>). This keeps the
  discussion private until a fix is available.
- **Email:** `security@example.com` *(placeholder — replace with the project's
  real security contact)*.

When reporting, please include where practical:

- A clear description of the issue and its impact.
- Steps to reproduce (proof-of-concept, affected version/commit, OS).
- Any relevant logs, configuration, or network conditions.

## Response Expectations

These are targets, not guarantees, for a volunteer-maintained project:

- **Acknowledgement:** within 5 business days.
- **Initial assessment / triage:** within 10 business days.
- **Fix or mitigation plan:** communicated once severity is confirmed; timeline
  depends on complexity and severity.

We will keep you informed of progress and coordinate public disclosure timing
with you.

## Scope

Opal is **local-first** and stores data on-device (SQLite DB and tokens in the
config dir, see `docs/PRIVACY.md`). The following surfaces are explicitly in
scope and worth focusing on:

### Local remote JSON API (`:41595`)

- The JSON remote-control API is intended to bind to **loopback
  (`127.0.0.1:41595`)** by default and is protected by **bearer-token auth**
  (constant-time comparison) plus **Host-header / loopback validation** to
  mitigate DNS-rebinding and cross-origin abuse.
- Token-bypass, auth weaknesses, Host-header check bypass, request smuggling,
  path traversal, SSRF, or local privilege issues against this API are in scope.

### Headless / `0.0.0.0` caveats

- In headless or explicitly LAN-exposed configurations, services may bind to
  **`0.0.0.0`**, and the watch-party listener (`:41596`) is unauthenticated by
  design when hosting. Exposing these beyond a trusted LAN is **out of the
  intended threat model** — but reports of unintended exposure, missing auth on
  surfaces meant to be authenticated, or LAN-to-internet escalation are welcome.

### Also in scope

- The companion web UI (`:3000`) and local AI/voice servers
  (llama-server, embeddings, lang server, voice backend, stream proxy).
- The `read_webpage` AI tool and other URL-fetching paths (SSRF).
- Memory-safety / parsing bugs in scrapers, the torrent wrapper, OCR, or media
  handling.

### Out of scope

- The **third-party plugin system**: plugins are user-installed and can run
  arbitrary native binaries **without sandboxing** by design. Compromise via a
  plugin the user chose to install is expected behavior, not a vulnerability in
  Opal itself. (Per-spawn OS sandboxing and consent prompts are known TODOs.)
- Risks inherent to **BitTorrent** participation (joining the public DHT/swarm
  exposes the user's IP) and to user-supplied content sources.
- The always-on launch update check and one-time `yt-dlp` download (documented;
  should-be-opt-in is tracked separately).
- Vulnerabilities in upstream dependencies (mpv, libtorrent, SDL2, onnxruntime,
  yt-dlp, etc.) — please report those to their respective projects, though we
  appreciate a heads-up.

## Responsible Disclosure

Please give us a reasonable opportunity to investigate and ship a fix before any
public disclosure, and avoid accessing or modifying data that is not yours,
degrading service for other users, or running automated scanning against hosts
you do not control. We are happy to credit reporters who follow coordinated
disclosure.

## No Warranty

Opal has had a security hardening pass, but the software is distributed **without
warranty of any kind**, express or implied. Use at your own risk, and prefer
running network-exposed surfaces only on trusted networks.
