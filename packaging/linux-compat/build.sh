#!/usr/bin/env bash
set -euo pipefail
cd "$(dirname "$0")/../.."
VERSION=${VERSION:-$(sed -n 's/.*\.version = "\([^"]*\)".*/\1/p' build.zig.zon | head -1)}
export VERSION
# Native x86_64 builder required; Docker can emulate it on other hosts.
docker buildx build --platform linux/amd64 --progress=plain \
    --file packaging/linux-compat/Dockerfile --target artifacts \
    --build-arg "OPAL_BUILD_CACHE_KEY=local-$(date +%s)" \
    --secret id=opal_tmdb,env=OPAL_TMDB_TOKEN --secret id=opal_omdb,env=OPAL_OMDB_KEY \
    --output type=local,dest=compat-artifacts .
if [ ! -x ./nfpm ]; then
    curl -fL --retry 3 https://github.com/goreleaser/nfpm/releases/download/v2.41.3/nfpm_2.41.3_Linux_x86_64.tar.gz -o /tmp/opal-nfpm.tar.gz
    tar -xzf /tmp/opal-nfpm.tar.gz nfpm
fi
./nfpm package -f packaging/linux-compat/nfpm.yaml -p deb -t "opal_${VERSION}_compat_amd64.deb"
# Complete corresponding source: upstream archives, app source and recipe.
mkdir -p compat-artifacts/sources/opal
# Exclude output, native objects and local/VCS configuration from app sources.
git archive HEAD | tar -x -C compat-artifacts/sources/opal
cp -R packaging/linux-compat compat-artifacts/sources/opal/packaging/
tar -C compat-artifacts/sources -czf "opal-${VERSION}-linux-compat-sources.tar.gz" .
