# Opal — dev shortcuts
#   just <task>   (run `just` alone for list)
# Requires: `brew install just`

zig := env("ZIG", "zig")

# List tasks
default:
    @just --list

# Normal dev run (fswatch-based, survives C changes + build.zig edits)
run:
    ./dev.sh

# Debug build only (incremental; no bundle, no launch)
debug:
    {{zig}} build

# Debug build + launch with the UI debugger (dvui widget inspector) open
ui-debug:
    ./scripts/ui-debug.sh

# Stop the app + every sidecar a dev run leaves behind (session still saves)
stop:
    ./scripts/stop-dev.sh

# Native zig 0.16 HMR — millisecond rebuilds on .zig edits.
# Bails on C/build.zig changes; use `just run` for those.
hot:
    {{zig}} build run --watch -fincremental --error-style minimal_clear

# Release build (stripped, optimized)
release:
    {{zig}} build -Doptimize=ReleaseFast

# Unit tests (m3u, paths)
test:
    {{zig}} build test

# Build + unit tests in one shot (what the pre-commit hook gates on)
check: debug test

# Comprehensive feature suite (DB, config, voice, ASR, theming + unit tests).
# The standard gate — run to confirm every feature still works. Writes a
# report to tests/results.json (viewable in tests/dashboard.html).
test-all:
    python3 tests/test_features.py

# Format all .zig in src/
fmt:
    {{zig}} fmt src/ build.zig

# Remove local build outputs (.zig-cache, zig-out) — deps stay cached
clean:
    ./scripts/clean.sh

# Also drop the packaged bundles in dist/
clean-bundles:
    ./scripts/clean.sh --bundle

# Nuke zig-pkg + the global Zig object cache too (slow; after a zig upgrade)
clean-all:
    ./scripts/clean.sh --all

# Build with verbose error traces (debug spurious compile errors)
debug-build:
    {{zig}} build -freference-trace=20

# Tail last build log
log:
    tail -f /tmp/opal-build.log

# Git pre-commit hook install
hooks:
    cp scripts/pre-commit .git/hooks/pre-commit
    chmod +x .git/hooks/pre-commit
    @echo "pre-commit installed — will run 'zig build' before each commit"

# Build Opal.app macOS bundle (ReleaseFast + Info.plist + dylibs).
# Optional: export CODESIGN_IDENTITY="Developer ID Application: Your Name" before running to sign.
# Optional: `brew install create-dmg` to get a distributable .dmg.
app:
    ./scripts/build-app.sh
    @echo "Bundle ready → dist/Opal.app"

# Build .app + open it
app-run: app
    open dist/Opal.app

# Build the ReleaseFast bundle, install to /Applications, launch (flags: --skip-build --no-launch --dest DIR)
install *ARGS:
    ./scripts/install-app.sh {{ARGS}}

# Build OpalMenubar.app standalone (Swift helper, LSUIElement).
menubar:
    ./scripts/build-menubar.sh
    @echo "Helper ready → dist/OpalMenubar.app"

# Build menubar helper + open it (runs detached, shows in macOS menu bar).
menubar-run: menubar
    open dist/OpalMenubar.app

# Full bundle: menubar helper + Opal.app with helper embedded as LoginItem.
app-full: menubar app
    @echo "Full bundle ready → dist/Opal.app (menubar embedded)"
