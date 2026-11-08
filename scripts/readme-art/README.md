# README artwork

`layout.html` defines the README's matte mineral palette, typography, and frames.
It uses the Opal logo, real screenshots, and original recordings. The texture is
an embedded SVG grain filter; exports need no generated background or network.

## Fresh native previews

Run from the repository root with Zig, ImageMagick, and native build dependencies:

```sh
python3 scripts/readme-art/capture-native.py
```

This captures the actual production shell, video surface, and transport controls
in hidden SDL windows with an isolated profile. It uses the checked-in, openly
licensed film frames in `assets/readme/sources/`; no download or screen-recording
permission is needed. The explicit `OPAL_README_CAPTURE=1` mode only runs when
requested and leaves the normal media layout checks unchanged. Review all three
exports after regenerating them. Film credits, sources, and the distinction
between paused-frame previews and live playback are in
[`assets/readme/CREDITS.md`](../../assets/readme/CREDITS.md).

## Legacy framed artwork

The remaining instructions cover the older HTML compositions and recordings,
which remain available for existing links.

## Render

Install ego-browser, FFmpeg, and ImageMagick, then use your checkout's absolute path:

```sh
ego-browser nodejs -e 'await import("file:///path/to/Opal/scripts/readme-art/render.mjs")'
```

To refresh selected views:

```sh
ego-browser nodejs -e 'globalThis.opalReadmeOptions = { views: ["hero", "hero-mobile"] }; await import("file:///path/to/Opal/scripts/readme-art/render.mjs")'
```

Available views: `hero`, `hero-mobile`, `search`, `player`, `connect`, `browse`,
`torrent`, `ai`. When integrating into a browser task, pass its TaskSpace as
`opalReadmeOptions.task`; the caller finishes that space after review.

The renderer captures HTML, exports WebP stills, and composites the original MP4
recordings into their exact screen slots. Sources in `assets/screenshots/` and
`assets/media/` stay intact. Temporary captures are printed for inspection.

## Presentation

The README uses one hero image, with a separate composition below 600 px. Hero
copy is also in its alt text; calls to action remain clickable Markdown links.

Browse and AI GIFs use 8 fps at 960 px; torrent uses 6 fps at 800 px. Each has a
WebP poster for `prefers-reduced-motion`. MP4 links offer smoother playback.
The main browse demo is visible; extra demos and screenshots are expandable.

Recordings predate the toolbar shown in the stills. Preserve the Blender
Foundation / CC BY 3.0 credits for Sintel and Big Buck Bunny when refreshing them.

Review desktop and phone layouts, check assets and anchors, and run
`git diff --check` before finishing.
