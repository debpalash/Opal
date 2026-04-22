# Opal — dev shortcuts
#   just <task>   (run `just` alone for list)
# Requires: `brew install just`

zig := "/opt/homebrew/bin/zig"

# List tasks
default:
    @just --list

# Normal dev run (fswatch-based, survives C changes + build.zig edits)
run:
    ./dev.sh

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

# Format all .zig in src/
fmt:
    {{zig}} fmt src/ build.zig

# Nuke all caches — slow recovery, use after upstream zig update
clean:
    rm -rf .zig-cache zig-out zig-pkg /Users/user4/.cache/zig/o

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
