# Native libraries and the app are compiled on Focal: no newer glibc ABI.
FROM ubuntu:20.04 AS runtime-build
ENV DEBIAN_FRONTEND=noninteractive
RUN apt-get update && apt-get install -y --no-install-recommends \
    build-essential pkg-config curl ca-certificates xz-utils cmake python3 python3-pip \
    ninja-build nasm patchelf python3-jinja2 libboost-system-dev libsqlite3-dev libass-dev \
    libluajit-5.1-dev libasound2-dev libpulse-dev libx11-dev libxext-dev \
    libxrandr-dev libxcursor-dev libxi-dev libxfixes-dev libxss-dev libgl1-mesa-dev \
    && rm -rf /var/lib/apt/lists/*
RUN python3 -m pip install --no-cache-dir meson==1.5.2
COPY packaging/linux-compat/build-runtime.sh /build-runtime.sh
RUN /build-runtime.sh
RUN curl -fL --retry 3 https://ziglang.org/download/0.16.0/zig-x86_64-linux-0.16.0.tar.xz -o /tmp/zig.tar.xz \
    && echo '70e49664a74374b48b51e6f3fdfbf437f6395d42509050588bd49abe52ba3d00  /tmp/zig.tar.xz' | sha256sum -c - \
    && tar -xJf /tmp/zig.tar.xz -C /opt && rm /tmp/zig.tar.xz
ENV PATH="/opt/zig-x86_64-linux-0.16.0:/opt/opal-runtime/bin:${PATH}"
ENV PKG_CONFIG_PATH="/opt/opal-runtime/lib/pkgconfig"
ENV LD_LIBRARY_PATH="/opt/opal-runtime/lib"
WORKDIR /src
COPY . .
# BuildKit keeps API keys out of image metadata and build arguments.
RUN --mount=type=secret,id=opal_tmdb --mount=type=secret,id=opal_omdb \
    OPAL_TMDB_TOKEN="$(cat /run/secrets/opal_tmdb 2>/dev/null || true)" \
    OPAL_OMDB_KEY="$(cat /run/secrets/opal_omdb 2>/dev/null || true)" \
    zig build -Doptimize=ReleaseSafe -Dcpu=x86_64_v2 -fsys=sdl2
RUN python3 packaging/linux-compat/stage.py
FROM scratch AS artifacts
COPY --from=runtime-build /compat-root /compat-root
COPY --from=runtime-build /opt/opal-sources /sources
