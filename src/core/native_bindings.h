#include <core/windows_bindings.h>
#define SDL_DISABLE_ARM_NEON_H 1
#ifndef OPAL_HEADLESS
#include <SDL2/SDL.h>
#include <ghostty/vt.h>
#endif
#include <core/sqlite/sqlite-vec.h>
#ifdef __APPLE__
#include <mach/mach.h>
#include <mach/mach_host.h>
#include <mach/task_info.h>
#include <sys/sysctl.h>
#endif
#include <mpv/client.h>
#include <mpv/render_gl.h>
#include <ocr_ort.h>
#include <sqlite3.h>
#include <stb_image.h>
#include <torrent_wrapper.h>
#ifndef _WIN32
#include <unistd.h>
#endif
