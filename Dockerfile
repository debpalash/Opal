# Opal — headless server image
#
# IMPORTANT: This Dockerfile is NOT verifiable on the macOS dev host. `docker
# build` on a real Linux/x86_64 host is the actual gate. Package names for
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
ARG ZIG_TARBALL=zig-x86_64-linux-${ZIG_VERSION}.tar.xz

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

# Headless entry (compile-time; no dvui frame loop at runtime — SDL is still
# LINKED this cycle, the no-SDL link is a follow-up). ReleaseSafe keeps
# runtime safety checks on for the server.
RUN zig build -Dheadless=true -Doptimize=ReleaseSafe

# Artifacts to copy out of the builder into the runtime stage:
#   - the opal binary              (zig-out/bin/opal)
#   - libtorrent_wrapper.so        (built by build.zig from src/torrent_wrapper.cpp)
#   - any ort/ shared lib          (PP-OCR ONNX pipeline, if produced as a .so)
#   - web/index.html               (web UI served by opal itself at :41595/)
#   - ONNX / whisper model assets  (model files the runtime loads)
# Exact output paths depend on build.zig install steps; verify on a real build.

# ---------------------------------------------------------------------------
# Runtime stage — runtime libs ONLY. No SDL2, no libX11, no mesa/xorg.
# ---------------------------------------------------------------------------
FROM debian:12-slim AS runtime

RUN apt-get update && apt-get install -y --no-install-recommends \
        libmpv2 \
        libsqlite3-0 \
        libtorrent-rasterbar2.0 \
        ffmpeg \
        ca-certificates \
        curl \
        # python3 only needed if the voice/TTS/STT sidecars are wanted:
        python3 \
    && rm -rf /var/lib/apt/lists/*

# Copy build artifacts. The app resolves web/index.html, engines/ and the
# plugin manifest relative to its working directory in dev layout, so keep
# that layout under /opt/opal and run from there.
COPY --from=builder /src/zig-out/bin/opal /usr/local/bin/opal
COPY --from=builder /src/libtorrent_wrapper.so /usr/local/lib/
COPY --from=builder /src/web/index.html /opt/opal/web/index.html
COPY --from=builder /src/plugins-manifest.json /opt/opal/plugins-manifest.json
COPY --from=builder /src/engines /opt/opal/engines
RUN ldconfig

# Mountable data dirs.
RUN mkdir -p /config /cache /media

# XDG dirs map config to ~/.config/opal, cache to ~/.cache/opal.
ENV XDG_CONFIG_HOME=/config \
    XDG_CACHE_HOME=/cache \
    HOME=/config \
    OPAL_HEADLESS=1

# One port: web UI + JSON API, served by opal itself. Pairing code prints to
# the container log on start (docker logs). OPAL_PAIR_CODE pins a fixed code.
EXPOSE 41595

# Non-root + liveness.
RUN useradd -r -m -d /config opal && chown -R opal /config /cache /media /opt/opal
USER opal
WORKDIR /opt/opal

# HEALTHCHECK hits /health — an unauthenticated liveness probe that returns
# {"ok":true} (see remote.zig handleRequest, served before the Bearer-auth
# gate). A clean 200 means the JSON API is up and serving.
HEALTHCHECK --interval=30s --timeout=5s --start-period=20s --retries=3 \
    CMD curl -fsS -o /dev/null http://localhost:41595/health

ENTRYPOINT ["/usr/local/bin/opal"]
