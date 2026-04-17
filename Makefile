# ZigZag Media Console — Build targets
# SDL_VIDEODRIVER=wayland forces native Wayland instead of XWayland.
# This is required for window title updates to work on COSMIC DE.
# -fsys=sdl2 uses the system's SDL2 (sdl2-compat/SDL3) which has Wayland support.

.PHONY: build run clean test release

build:
	zig build -fsys=sdl2

run:
	SDL_VIDEODRIVER=wayland zig build -fsys=sdl2 run

release:
	zig build -fsys=sdl2 -Doptimize=ReleaseSafe

clean:
	rm -rf zig-out .zig-cache

test:
	zig build -fsys=sdl2 test
