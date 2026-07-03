# Opal — headless server image
#
# IMPORTANT: This Dockerfile is NOT verifiable on the macOS dev host. `docker
# build` on a real Linux/x86_64 host is the actual gate. Package names for
# onnxruntime / libtorrent are best-effort for debian:12 (bookworm) and may
# need adjustment (vendored install) per distro. See docs/headless-deploy.md.
#
# torrent_wrapper.cpp is compiled INSIDE this container by build.zig — it is
# never cross-compiled from macOS. That is why the builder installs g++ and the
# -dev packages the build links against.

# ---------------------------------------------------------------------------
# Builder stage
# ---------------------------------------------------------------------------
FROM debian:12-slim AS builder

# Pin a 0.16.x Zig (project requires 0.16.x). Adjust ZIG_VERSION as 0.16.x
# point releases land; the URL is the official tarball for linux-x86_64.
ARG ZIG_VERSION=0.16.0
ARG ZIG_TARBALL=zig-linux-x86_64-${ZIG_VERSION}.tar.xz

RUN apt-get update && apt-get install -y --no-install-recommends \
        build-essential \
        g++ \
        pkg-config \
        curl \
        ca-certificates \
        xz-utils \
        # -dev packages the build links against:
        libmpv-dev \
        libsqlite3-dev \
        # onnxruntime: debian may not ship a -dev package. If
        # `libonnxruntime-dev` is unavailable, vendor the ONNX Runtime release
        # tarball into /usr/local and point pkg-config/the build at it.
        libonnxruntime-dev \
        libtorrent-rasterbar-dev \
        ffmpeg \
    && rm -rf /var/lib/apt/lists/*

# Install Zig 0.16.x onto PATH.
RUN curl -fsSL "https://ziglang.org/download/${ZIG_VERSION}/${ZIG_TARBALL}" -o /tmp/zig.tar.xz \
    && mkdir -p /opt/zig \
    && tar -xJf /tmp/zig.tar.xz -C /opt/zig --strip-components=1 \
    && rm /tmp/zig.tar.xz
ENV PATH="/opt/zig:${PATH}"

WORKDIR /src
COPY . .

# Normal build (full dvui/SDL is still linked — a headless/no-SDL build is the
# follow-up per T7). ReleaseSafe keeps runtime safety checks on for the server.
RUN zig build -Doptimize=ReleaseSafe

# Artifacts to copy out of the builder into the runtime stage:
#   - the opal binary              (zig-out/bin/opal)
#   - libtorrent_wrapper.so        (built by build.zig from src/torrent_wrapper.cpp)
#   - any ort/ shared lib          (PP-OCR ONNX pipeline, if produced as a .so)
#   - the web/ dir                 (web UI served on :3000)
#   - ONNX / whisper model assets  (model files the runtime loads)
# Exact output paths depend on build.zig install steps; verify on a real build.

# ---------------------------------------------------------------------------
# Runtime stage — runtime libs ONLY. No SDL2, no libX11, no mesa/xorg.
# ---------------------------------------------------------------------------
FROM debian:12-slim AS runtime

RUN apt-get update && apt-get install -y --no-install-recommends \
        libmpv2 \
        libsqlite3-0 \
        # onnxruntime runtime lib — if no distro package, copy the vendored
        # shared lib in from the builder / a release tarball instead.
        libonnxruntime1.16 \
        libtorrent-rasterbar2.0 \
        ffmpeg \
        ca-certificates \
        curl \
        # python3 only needed if the voice/TTS/STT sidecars are wanted:
        python3 \
    && rm -rf /var/lib/apt/lists/*

# Copy build artifacts. Adjust source paths to match build.zig install layout.
COPY --from=builder /src/zig-out/bin/opal /usr/local/bin/opal
# COPY --from=builder /src/zig-out/lib/libtorrent_wrapper.so /usr/local/lib/
# COPY --from=builder /src/zig-out/lib/libocr_ort.so /usr/local/lib/
COPY --from=builder /src/web /opt/opal/web
# COPY --from=builder /src/models /opt/opal/models   # ONNX/whisper assets
# RUN ldconfig

# Mountable data dirs.
RUN mkdir -p /config /cache /media

# XDG dirs map config to ~/.config/opal, cache to ~/.cache/opal.
ENV XDG_CONFIG_HOME=/config \
    XDG_CACHE_HOME=/cache \
    HOME=/config \
    OPAL_HEADLESS=1

# JSON API (41595) + web UI (3000).
EXPOSE 41595 3000

# HEALTHCHECK hits /health — an unauthenticated liveness probe that returns
# {"ok":true} (see remote.zig handleRequest, served before the Bearer-auth
# gate). A clean 200 means the JSON API is up and serving.
HEALTHCHECK --interval=30s --timeout=5s --start-period=20s --retries=3 \
    CMD curl -fsS -o /dev/null http://localhost:41595/health

ENTRYPOINT ["/usr/local/bin/opal"]
