#!/usr/bin/env bash
# Fetch the Zig package tree with retries, so the build that follows is offline
# for packages.
#
#   scripts/zig-fetch-retry.sh [extra zig build args, e.g. --build-file X]
#
# codeberg.org (translate-c, arocc) intermittently refuses GitHub runners with
# "unable to discover remote git server capabilities: ProtocolError". The
# v0.9.7 release lost its macOS job twice and its Android job once to it.
set -uo pipefail

attempts=${ZIG_FETCH_ATTEMPTS:-5}
for i in $(seq 1 "$attempts"); do
    if zig build --fetch "$@"; then
        exit 0
    fi
    if [ "$i" -lt "$attempts" ]; then
        echo "zig build --fetch failed (attempt $i/$attempts); retrying in $((i * 30))s" >&2
        sleep $((i * 30))
    fi
done
echo "zig build --fetch failed after $attempts attempts" >&2
exit 1
