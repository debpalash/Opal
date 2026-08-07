/* Native Win32 fixes for the custom (client-side) title bar.
 *
 * ui/titlebar.zig makes the window borderless and draws its own bar. Two
 * behaviors that a native title bar gets for free are broken for a borderless
 * SDL2 window, and neither can be fixed through the SDL API — both need the
 * window procedure, so this file subclasses it and forwards everything else.
 *
 * 1. Maximize covered the taskbar. SDL2 answers WM_GETMINMAXINFO for a
 *    borderless+resizable window with the raw *screen* metrics
 *    (SDL_windowsevents.c: ptMaxSize = SM_CXSCREEN/SM_CYSCREEN, ptMaxPosition
 *    = 0,0), not the monitor work area, so ShowWindow(SW_MAXIMIZE) produced a
 *    fullscreen-looking window on top of the taskbar. Those metrics are also
 *    the *primary* monitor's, so maximizing on a secondary monitor was wrong
 *    twice over. We let SDL fill the struct, then overwrite the maximize
 *    geometry with the work area of the monitor the window is actually on.
 *
 * 2. Double-clicking the title bar did nothing. The hit test reports
 *    SDL_HITTEST_DRAGGABLE -> HTCAPTION, but DefWindowProc only maximizes on a
 *    caption double-click when the window has WS_MAXIMIZEBOX, and SDL2 omits
 *    WS_MAXIMIZEBOX/WS_THICKFRAME from borderless windows unless the
 *    undocumented SDL_BORDERLESS_RESIZABLE_STYLE hint is set. Setting that hint
 *    would also add a non-client resize frame and change how the window is
 *    drawn, so we handle the double-click here instead and leave the style
 *    alone. ShowWindow(SW_MAXIMIZE/SW_RESTORE) goes through the window
 *    manager, so the pre-maximize size is remembered and restored natively.
 *
 * Windows-only; build.zig compiles this into the desktop build exclusively.
 */

#ifdef _WIN32

#include <windows.h>

#include <SDL2/SDL.h>
#include <SDL2/SDL_syswm.h>

static WNDPROC g_prev_proc;
static SDL_Window *g_window;

/* Maximize to the work area (screen minus taskbar/appbars) of the monitor the
 * window currently sits on. ptMaxPosition is relative to the monitor origin,
 * not the desktop, which is what makes this correct on secondary monitors. */
static void clampMaximizeToWorkArea(HWND hwnd, MINMAXINFO *mmi)
{
    MONITORINFO mi;
    HMONITOR mon = MonitorFromWindow(hwnd, MONITOR_DEFAULTTONEAREST);
    if (!mon) {
        return;
    }
    mi.cbSize = sizeof(mi);
    if (!GetMonitorInfoW(mon, &mi)) {
        return;
    }
    mmi->ptMaxPosition.x = mi.rcWork.left - mi.rcMonitor.left;
    mmi->ptMaxPosition.y = mi.rcWork.top - mi.rcMonitor.top;
    mmi->ptMaxSize.x = mi.rcWork.right - mi.rcWork.left;
    mmi->ptMaxSize.y = mi.rcWork.bottom - mi.rcWork.top;
}

static LRESULT CALLBACK opalWndProc(HWND hwnd, UINT msg, WPARAM wparam, LPARAM lparam)
{
    switch (msg) {
    case WM_GETMINMAXINFO: {
        /* SDL first: it also enforces the window's min/max size constraints. */
        LRESULT res = CallWindowProcW(g_prev_proc, hwnd, msg, wparam, lparam);
        /* Real fullscreen (the video player's FULLSCREEN_DESKTOP) is *supposed*
         * to cover the taskbar — only clamp ordinary maximize. */
        Uint32 flags = g_window ? SDL_GetWindowFlags(g_window) : 0;
        if (!(flags & SDL_WINDOW_FULLSCREEN)) {
            clampMaximizeToWorkArea(hwnd, (MINMAXINFO *)lparam);
        }
        return res;
    }
    case WM_NCLBUTTONDBLCLK:
        if (wparam == HTCAPTION) {
            ShowWindow(hwnd, IsZoomed(hwnd) ? SW_RESTORE : SW_MAXIMIZE);
            return 0;
        }
        break;
    default:
        break;
    }
    return CallWindowProcW(g_prev_proc, hwnd, msg, wparam, lparam);
}

/* Idempotent; safe to call every frame. Must run on the thread that owns the
 * window (the UI thread), like every other window-manipulating call here. */
void opal_titlebar_install_native(SDL_Window *win)
{
    SDL_SysWMinfo info;
    HWND hwnd;

    if (g_prev_proc != NULL || win == NULL) {
        return;
    }
    SDL_VERSION(&info.version);
    if (!SDL_GetWindowWMInfo(win, &info) || info.subsystem != SDL_SYSWM_WINDOWS) {
        return;
    }
    hwnd = info.info.win.window;
    if (hwnd == NULL) {
        return;
    }
    g_window = win;
    /* The W variants matter: SDL registers a Unicode window class, and
     * subclassing with the ANSI entry points would silently convert the window
     * to ANSI and mangle IME / non-Latin text input. */
    g_prev_proc = (WNDPROC)(LONG_PTR)SetWindowLongPtrW(hwnd, GWLP_WNDPROC, (LONG_PTR)opalWndProc);
}

#endif /* _WIN32 */
