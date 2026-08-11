# Windows packaging

- `opal.wxs` — WiX 3 authoring for the MSI: product identity (the UpgradeCode is fixed forever — never regenerate it), per-machine install to `Program Files\Opal`, Start Menu shortcut, ARP metadata. The file payload is *not* listed here.
- `opal.ico` — multi-size (16–256px) icon rendered from `assets/logo.svg` (`rsvg-convert` per size, then `magick *.png opal.ico`). Regenerate only when the logo changes.

**Environment: MSYS2/MINGW64 + vendored Microsoft onnxruntime** (issue #3). zig's `x86_64-windows-gnu` target produces MSVCRT-flavored MinGW binaries; the v0.1.0 job built against UCRT64 packages and the CRT mismatch broke launches on user machines ("entry point strtod could not be located"). MINGW64 packages match zig's CRT. onnxruntime has no mingw64 package, so the job vendors Microsoft's official MSVC release (`onnxruntime-win-x64-<ver>.zip`; MSVC-built but pure C ABI — safe to link via its COFF import lib) and points `build.zig` at it with `ONNXRUNTIME_DIR`.

**DLL harvest** (see the `windows-x86_64` job in `.github/workflows/release.yml`): the job copies `opal.exe`, the torrent wrapper, `onnxruntime.dll` (+ the msvcp140/vcruntime140 runtime it needs) into `staging/`, then runs `ldd` over everything staged **to a fixpoint** — each pass copies every dependency under `$MINGW_PREFIX` (`/mingw64`) not yet staged, until a pass adds nothing (a single pass misses transitive deps like `libbrotlidec`/`libintl-8`; that's how v0.1.0 shipped broken). Unresolvable imports fail the job, and a non-MSYS2 `pwsh` step then launches `staging/opal.exe` and asserts it survives 10 s — the same DLL-search environment as a user's machine. The same `staging/` dir becomes both the portable zip and, via `heat.exe dir staging -cg OpalFiles`, the MSI's file fragment (`candle` + `light` link it against `opal.wxs`).

**Code signing** (the `Sign the payload` / `Sign the MSI` steps in the `windows-x86_64` job). Smart App Control ships on by default on clean Windows 11 installs and, unlike SmartScreen, offers the user no way to click past a block. Microsoft's SAC FAQ describes the decision order: the cloud is asked first, and *when it has no confident verdict — the normal case for a new release from a small publisher — SAC falls back to the signature and treats an unsigned file as untrusted*. There is no allowlist, no per-app review, and no exception process, so signing is the only available lever. SAC also evaluates **every module it loads**, so the whole staged closure (~50 MSYS2 DLLs) and the MSI are signed, not just `opal.exe`; a single unsigned straggler is enough to trip it, which is why the job hard-fails if one survives.

Signing is **opt-in**: with no `AZURE_CLIENT_ID` repo secret the steps skip and the job still produces unsigned artifacts, so forks are unaffected. To enable it, create an [Azure Artifact Signing](https://azure.microsoft.com/en-us/products/artifact-signing) account (formerly Trusted Signing; $9.99/mo Basic) — it requires identity validation, and individual developers are eligible in the US, Canada, EU and UK. Then set six repo secrets:

| Secret | Example |
| --- | --- |
| `AZURE_CLIENT_ID` / `AZURE_TENANT_ID` / `AZURE_SUBSCRIPTION_ID` | the app registration federated to this repo via OIDC |
| `AZURE_SIGNING_ENDPOINT` | `https://eus.codesigning.azure.net/` (region-specific) |
| `AZURE_SIGNING_ACCOUNT` | signing account name |
| `AZURE_SIGNING_PROFILE` | certificate profile name |

The identity needs the **Trusted Signing Certificate Profile Signer** role. Keep the certificate RSA — the Code Integrity path SAC uses does not accept ECC signatures.

Signing removes the SmartScreen interstitial and satisfies SAC's signature fallback, but it does not make a brand-new binary *reputable*: reputation accrues per publisher as installs accumulate, and it accrues across releases with a stable certificate rather than resetting per file hash as it does for unsigned builds.

**Iterating locally on a Windows box**: install [MSYS2](https://www.msys2.org), open a *MINGW64* shell, `pacman -S unzip mingw-w64-x86_64-{gcc,SDL2,mpv,sqlite3,libtorrent-rasterbar,pkgconf}`, unpack `onnxruntime-win-x64-<ver>.zip` from github.com/microsoft/onnxruntime/releases and `export ONNXRUNTIME_DIR=<its root>`, put zig 0.16 on PATH, then `zig build -Doptimize=ReleaseSafe` and replay the workflow's staging/heat/candle/light steps verbatim (WiX 3.14 from wixtoolset.org if not preinstalled). Pin an onnxruntime whose DLL serves the `ORT_API_VERSION` in `ort/onnxruntime_c_api.h` (currently 24 → 1.24.x).
