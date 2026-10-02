# README artwork

`layout.html` defines the README's matte mineral palette, typography, and frames.
It uses the Opal logo, real screenshots, and original recordings. The texture is
an embedded SVG grain filter; exports need no generated background or network.

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
