#!/usr/bin/env bash
# Vendor Microsoft's prebuilt ONNX Runtime for a release job.
#
#   scripts/vendor-onnxruntime.sh linux|windows VERSION SHA256 DEST
#
# Source: the Microsoft.ML.OnnxRuntime NuGet package (Microsoft's own build).
# github.com/microsoft/onnxruntime stopped serving its release archives in
# November 2026; the package holds the same headers and libraries. The download
# is pinned by SHA-256. DEST gets the archive layout the jobs used before:
#   DEST/include/*.h  and  DEST/lib/<libraries>
set -euo pipefail

os=${1:?linux|windows}
ver=${2:?version}
want=${3:?sha256}
dest=${4:?destination}

case "$os" in
    linux) rid=linux-x64 ;;
    windows) rid=win-x64 ;;
    *) echo "unknown os: $os" >&2; exit 2 ;;
esac

work=$(mktemp -d)
trap 'rm -rf "$work"' EXIT
pkg="$work/ort.nupkg"
curl -fsSL --retry 3 --proto '=https' --proto-redir '=https' -o "$pkg" \
    "https://api.nuget.org/v3-flatcontainer/microsoft.ml.onnxruntime/${ver}/microsoft.ml.onnxruntime.${ver}.nupkg"

if command -v sha256sum >/dev/null 2>&1; then
    got=$(sha256sum "$pkg" | cut -d' ' -f1)
else
    got=$(shasum -a 256 "$pkg" | cut -d' ' -f1)
fi
if [ "$got" != "$want" ]; then
    echo "onnxruntime ${ver} nupkg sha256 mismatch: got $got want $want" >&2
    exit 1
fi

unzip -q "$pkg" 'build/native/include/*' "runtimes/${rid}/native/*" -d "$work/x"
mkdir -p "$dest/include" "$dest/lib"
cp "$work/x/build/native/include/"*.h "$dest/include/"
native="$work/x/runtimes/${rid}/native"
if [ "$os" = linux ]; then
    # The archive shipped libonnxruntime.so.<ver> with soname links; the
    # package ships one file. Recreate the soname the binary records.
    soname=$(objdump -p "$native/libonnxruntime.so" | awk '/SONAME/{print $2}')
    test -n "$soname"
    cp "$native/libonnxruntime.so" "$dest/lib/$soname"
    ln -sf "$soname" "$dest/lib/libonnxruntime.so"
    cp "$native/libonnxruntime_providers_shared.so" "$dest/lib/"
else
    cp "$native/onnxruntime.dll" "$native/onnxruntime.lib" "$dest/lib/"
    cp "$native/onnxruntime_providers_shared.dll" "$native/onnxruntime_providers_shared.lib" "$dest/lib/"
fi
test -f "$dest/include/onnxruntime_c_api.h"
ls "$dest/lib"
