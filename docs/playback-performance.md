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

## GPU render path

On macOS and Linux, video now renders through libmpv's OpenGL render API
(`src/player/gpu_video.zig`). SDL is asked for its OpenGL renderer at startup.
Each player's render worker owns a GL context that shares objects with SDL's;
mpv draws into three SDL-owned textures (triple buffered), so there is no
per-frame CPU colour conversion or texture upload. Scaling and HDR tone
mapping run on the GPU, and output goes up to 4K instead of the software
path's 1080p cap.

Measured on an M2 (2026-11-20, VideoToolbox copy decode):

| Source → output | Software path | GPU path |
|---|---|---|
| 1080p24 HEVC Main 10 → 1080p | 24 fps, 0 drops, 7.3 ms CPU/frame | 24 fps, 0 drops |
| 4K60 HEVC 10-bit → 1080p | 52.9 fps, 39 drops in 6 s | 60.1 fps, 0 drops |
| 4K60 HEVC 10-bit → 4K | not available (1080p cap) | 59.6 fps, 3 drops in 8 s |

Real HDR sources (Jellyfin's public test clips, 4K HEVC 10-bit, PQ/BT.2020),
played at film rate (24 fps) on a loaded M2 Air:

| Source → output | Software path | GPU path |
|---|---|---|
| HDR10, 100 Mbit/s → 1080p | 0 drops; 18 ms CPU/frame, spikes to 113 ms | 0 drops |
| HDR10, 100 Mbit/s → 4K | not available | 0 drops |
| Dolby Vision P8.1 → 1080p | 0 drops; 24 ms CPU/frame, spikes to 98 ms | 0 drops |
| Dolby Vision P8.1 → 4K | not available | 0 drops |

The software path's spikes exceed the 41.7 ms frame budget, so it stutters as
soon as the CPU is busy; the GPU path leaves the CPU idle. At 60 fps, 4K HDR
output is at the M2 Air's GPU limit (45–55 fps under load); 1080p output holds
60 fps. VideoToolbox zero-copy needs a GL 3.2 core context, which SDL's
OpenGL renderer cannot share, so decoding uses `videotoolbox-copy`; on a GL
core context mpv also enables heavier HDR processing and measured no faster.

Windows keeps the software path by default because switching would move the
whole UI from Direct3D to OpenGL; `OPAL_VIDEO_RENDER=gpu` opts in and
`OPAL_VIDEO_RENDER=sw` forces software anywhere. Any failure (non-OpenGL
renderer, no shared context, mpv refusing the context) falls back to the
software path. Frame OCR takes the decoded frame from mpv's
`screenshot-raw` on the GPU path.
