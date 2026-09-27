# Playback performance

## Native player baseline

Measured on an M2 MacBook Air with 16 GB memory using a ReleaseFast build and
local H.264 1080p60 and 4K60 clips. Set `OPAL_PLAYBACK_STATS=1` to emit the same
five-second counters.

- Video decoding uses VideoToolbox hardware acceleration.
- A 60 fps video now drives about 60–61 UI frames per second. Previously the
  render callback, mpv client callback and upload refresh combined to produce
  about 118–120 complete UI passes per second.
- Client events are coalesced with their matching published video frame.
  Audio-only, paused and loading states remain event-driven with client wakes
  capped at 30 Hz.
- With no work pending, the main thread waits in SDL's event loop instead of
  polling or running a display-rate playback timer.
- The high-quality zimg scaler remains enabled. Faster low-quality scalers were
  rejected because they softened 4K downscaling or dropped frames.
- Software render targets follow the physical player viewport and stay capped
  to the source resolution. A 960×540 pane therefore converts and uploads about
  2.1 MB per frame instead of the 8.3 MB needed by a fixed 1080p texture.
  Targets use 64-pixel buckets so resizing does not recreate a texture for
  every pixel of window movement. Fit, Balanced and Fill each retain the pixels
  needed for their visible crop.

The current software render path still copies mpv output into an SDL texture.
Eliminating that copy requires a shared GPU rendering path between libmpv and
the application renderer and is tracked as a larger architecture change.
