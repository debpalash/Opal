# Release a version people can see

Every release ships a short explanation and at least one fresh visual of what
changed. This applies to patches too: show the corrected interaction when useful.
Do not reuse an unrelated hero image to satisfy the check.

1. Bump `build.zig.zon` and write the matching dated `CHANGELOG.md` section.
   Lead with what someone can now do. State platform limits next to the feature.
2. Capture the current app with public or owned demo content. Export one clear
   screenshot or a short GIF; keep personal history, accounts and credentials out.
   Label staged data and previews. A GIF shows an interaction, not a decorative loop.
3. Put PNG/GIF exports under `assets/releases/vX.Y.Z/`. Add
   `docs/releases/vX.Y.Z/media.json` with the exact tag and `items` containing
   `path`, descriptive `alt`, and a short `caption` explaining the improvement.
   Keep each visual below 8 MiB and at least 600 × 300. Include a still for readers
   who prefer reduced motion when embedding GIFs in the README.
4. Run `python3 scripts/release-media.py vX.Y.Z` and preview
   `scripts/release-notes.sh vX.Y.Z`. Notes embed images from that immutable tag.
   The release workflow blocks publication if the visual manifest is missing or invalid.
5. Run the unit and feature gates, build and launch the installed app, then merge,
   tag and watch every required packaging job through publication. Verify download
   names and checksums. Never announce a published release before its assets exist.
6. Refresh the README’s first screenshot when the main workflow changes. Put the
   benefit and download link before setup detail. Preserve credits for demo media.

## Export the browser and update flow

These are actual SDL-rendered app widgets with owned fixture state, not desktop
screen recording. No private history or live network requests are needed:

```sh
OPAL_NATIVE_CAPTURE_DIR=/tmp/opal-release-capture zig build test-native-updater
python3 scripts/export-release-visuals.py vX.Y.Z /tmp/opal-release-capture
```

The update test uses an illustrative next version. Label it as a preview in the
caption. The export script needs ImageMagick (`magick`) and FFmpeg; validation has
no extra Python dependencies. Review the exported files before committing.

## Sharing a release

Prepare a short post: one concrete improvement, one visual, a direct download
link, platform availability, and a clear invitation for feedback. Share it only
when the maintainer chooses to publish. Ask for a star once in the README if the
app is useful; avoid repeated prompts in the app. Downloads and stars are outcomes
to measure, not numbers to promise.
