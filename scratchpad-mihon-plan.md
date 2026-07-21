# Mihon (Tachiyomi) extensions support + ingest — plan

## What wotaku.wiki/ext/mihon documents
It lists community **extension repositories** for Mihon (manga) and Aniyomi (anime).
Each repo publishes a single catalog file `index.min.json` at a raw URL. Mihon/Suwayomi
consume these by registering the URL under "Extension repos", then install individual
extensions from the catalog. Recommended repos (verified URLs):

- Keiyoushi (manga): `https://raw.githubusercontent.com/keiyoushi/extensions/repo/index.min.json`
- Yūzōnō (manga):   `https://raw.githubusercontent.com/yuzono/manga-repo/repo/index.min.json`
- Yūzōnō (anime):   `https://raw.githubusercontent.com/yuzono/anime-repo/repo/index.min.json`
- Secozzi (anime):  `https://raw.githubusercontent.com/Secozzi/aniyomi-extensions/refs/heads/repo/index.min.json`
- Suwayomi (manga): `https://raw.githubusercontent.com/Suwayomi/tachiyomi-extension/repo/index.min.json`

### index.min.json shape (verified against keiyoushi)
Top-level JSON array; each element:
```json
{ "name":"Tachiyomi: AHottie", "pkg":"eu.kanade.tachiyomi.extension.all.ahottie",
  "apk":"tachiyomi-all.ahottie-v1.4.3.apk", "lang":"all", "code":3, "version":"1.4.3",
  "nsfw":1,
  "sources":[{"name":"AHottie","lang":"all","id":"6289731484943315811","baseUrl":"https://ahottie.top"}] }
```
`pkg` is unique per extension (good array delimiter). `sources[]` may hold >1 source.

## Existing Opal Mihon support
Opal already talks to a user-run **Suwayomi-Server** (`localhost:4567`) over `/api/v1`,
which RUNS the extension APKs. Files:
- `src/services/manga_suwayomi_pure.zig` — tested pure engine: REST URL builders + search/
  chapters/pages JSON. Routed by `src/services/comics.zig` (Source.suwayomi, gated on
  source_config `suwayomi/base` + `suwayomi/source`). Cards use `suwayomi:<mangaId>`.
- `tests/features/test_suwayomi.py`, manifest `suwayomi` plugin.

What's MISSING = "extensions support + ingest": nothing fetches/parses a Mihon repo
`index.min.json`, nothing knows the curated repo URLs, and there are no builders for
Suwayomi's extension endpoints (list/install/uninstall/icon). Users can't discover or
install extensions from Opal.

## Suwayomi extension REST endpoints (verified, DeepWiki)
- `GET /api/v1/extension/list`            — installed + available extensions
- `GET /api/v1/extension/install/{pkg}`   — install by package name
- `GET /api/v1/extension/uninstall/{pkg}`
- `GET /api/v1/extension/update/{pkg}`
- `GET /api/v1/extension/icon/{apkName}`
(Repo *registration* itself is a server-side setting `extensionRepos`, not a plain REST
call — so Opal surfaces the curated URLs for the user to add, and can drive install once
the repo is registered.)

## Deliverable this pass (self-contained, low-risk)
New tested pure module `src/services/mihon_repo_pure.zig` owning ALL Mihon-repo logic:
1. `REPOS` — curated repo table (name/kind/url) from wotaku.
2. `normalizeRepoIndexUrl` + `isValidIndexUrl` — accept a repo URL, ensure `index.min.json`.
3. index.min.json parsing — `ExtIter` (delimited by `"pkg":`) + `parseExtension` →
   name/pkg/apk/lang/version/nsfw + source_count + first source id/name/baseUrl. This IS
   the ingest of the browsable extension/source catalog. Mirrors `MangaIter`/`parseManga`.
4. Suwayomi extension endpoint builders + `isValidBase`/`isPkgName`/`isApkName` security
   gates (pkg/apk go straight into request paths). Mirrors manga_suwayomi_pure gates.

Wiring (within ownership): `manga_suwayomi_pure.zig` re-exports it as `pub const repo =
@import("mihon_repo_pure.zig");` so it joins the app module graph through comics.zig's
existing import and a future UI caller is one line (`suwayomi.repo.buildInstallUrl(...)`).

## Test plan
- `test "…"` blocks in `mihon_repo_pure.zig`: URL normalize/validate, curated table sanity,
  security gates (reject path escapes), index.min.json parse (multi-source, nsfw), endpoint
  builders. Registered in `build.zig` test step (append after manga_suwayomi_pure block).
- New `tests/features/test_mihon.py`: pure module present + routed via re-export, endpoint
  builders, curated repos, manifest `mihon` entry, build registration.
- Manifest: add a `mihon` plugin entry carrying the curated repo URLs.

## Patterns reused
- `manga_suwayomi_pure.zig` — gates + jsonStr/jsonInt + `MangaIter`/`parseManga`.
- `iptv_catalog.zig` — fetch→parse→store ingest shape (for the follow-up live wiring).

## Out of scope this pass (Left to do — touches non-owned files / in-flight)
- comics.zig / ui: an "Extensions" browse panel that fetches `index.min.json`, lists
  extensions, and POSTs install to Suwayomi; persisting registered repos. Owned by the
  in-flight change (state.zig / ui) — one-line callers into `suwayomi.repo.*`.
