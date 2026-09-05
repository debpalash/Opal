# TV UI validation — 2026-09-05

Native Linux SDL build, ReleaseSafe, isolated HOME/XDG profile and Xvfb display.
No changes to the user's library or active player. Screenshots were inspected
after layout settled, not in the same frame as a resize.

| Viewport | Check | Result |
| --- | --- | --- |
| 1280 × 900 | Real keyless show, landscape art and wrapped descriptions | Passed |
| 768 × 1024 | Season 2, watched toggle, saved database state | Passed |
| 375 × 812 | Stacked cards, wrapped controls, themed season popup | Passed |
| 1024 × 400 | Scroll past the header to episodes | Passed |
| 320 × 700 | Missing art, long title/description, 75-season fixture | Passed |

The controlled metadata fixture replaced only the test process's Cinemeta
series response using a PATH-local curl wrapper. Its 75 seasons each contained
one episode with a long title and description, and no thumbnail. The last
season remained reachable by scrolling; selecting it closed the popup.

Real metadata checks used Breaking Bad with no user catalog API key. Resume
opened the buffering view for S01E02; Ctrl+W closed that test process cleanly.
This checks routing and buffering feedback, not sustained playback quality.

Visual testing found and fixed vertically centered children overlapping in
stacked headers, a season popup that stayed open after selection, and Retry
not re-fetching an unavailable season list. Source regression checks accompany
these fixes; pure layout tests exercise breakpoint and thumbnail calculations.

These checks do not establish native macOS/Windows behavior or exhaustive
keyboard/screen-reader accessibility. Release builds run separately in CI.
