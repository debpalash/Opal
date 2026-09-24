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
/* Same fractions used by SDL's title-bar hit-test. The player paints the bar
 * inside its UI-scale layer, so hard-coded 30/132 window units are wrong there. */
static float g_band_frac = 0.05f;
static float g_controls_frac = 0.85f;

void opal_titlebar_set_geometry(float band, float controls)
{
    g_band_frac = band;
    g_controls_frac = controls;
}

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
    case WM_NCHITTEST: {
        RECT wr;
        LRESULT hit = CallWindowProcW(g_prev_proc, hwnd, msg, wparam, lparam);
        /* Preserve the SDL/native resize edges. If the SDL callback did not
         * promote our custom title band, return a real caption hit so Windows
         * owns dragging, drag-to-restore, and Aero Snap. */
        if (hit != HTCLIENT || !g_window || !GetWindowRect(hwnd, &wr)) {
            return hit;
        }
        if (wr.right > wr.left && wr.bottom > wr.top) {
            const int physical_w = wr.right - wr.left;
            const int physical_h = wr.bottom - wr.top;
            const int title_h = (int)(physical_h * g_band_frac);
            const int controls_x = wr.left + (int)(physical_w * g_controls_frac);
            const int x = (int)(short)LOWORD(lparam);
            const int y = (int)(short)HIWORD(lparam);
            if (y >= wr.top && y < wr.top + title_h && x < controls_x) {
                return HTCAPTION;
            }
        }
        return hit;
    }
    case WM_NCCALCSIZE:
        /* Retain native resize/snap style bits without showing their standard
         * non-client frame; Opal draws the entire title area itself. */
        if (wparam) {
            return 0;
        }
        break;
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

    if (win == NULL) {
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
    if (g_prev_proc == NULL) {
        g_prev_proc = (WNDPROC)(LONG_PTR)SetWindowLongPtrW(hwnd, GWLP_WNDPROC, (LONG_PTR)opalWndProc);
    }
    {
        LONG_PTR style = GetWindowLongPtrW(hwnd, GWL_STYLE);
        /* Keep the native caption contract even though WM_NCCALCSIZE removes
         * its visible area. Windows 11 uses it with WS_MAXIMIZEBOX to enable
         * Snap Layouts for custom-drawn title bars. */
        LONG_PTR desired = style | WS_CAPTION | WS_THICKFRAME |
                           WS_MAXIMIZEBOX | WS_MINIMIZEBOX | WS_SYSMENU;
        if (desired != style) {
            SetWindowLongPtrW(hwnd, GWL_STYLE, desired);
            SetWindowPos(hwnd, NULL, 0, 0, 0, 0,
                         SWP_NOMOVE | SWP_NOSIZE | SWP_NOZORDER |
                         SWP_NOACTIVATE | SWP_FRAMECHANGED);
        }
    }
}

/* Begin the real Windows caption-move loop from a client-area gesture. This
 * preserves Aero Snap, multi-monitor dragging, and drag-to-restore behavior;
 * manually calling SDL_SetWindowPosition on every mouse move would lose all
 * three. The caller waits for a small motion threshold before entering here,
 * so an ordinary click can retain its player action. */
int opal_titlebar_begin_native_drag(SDL_Window *win)
{
    SDL_SysWMinfo info;
    HWND hwnd;

    if (win == NULL) {
        return 0;
    }
    SDL_VERSION(&info.version);
    if (!SDL_GetWindowWMInfo(win, &info) || info.subsystem != SDL_SYSWM_WINDOWS) {
        return 0;
    }
    hwnd = info.info.win.window;
    if (hwnd == NULL) {
        return 0;
    }

    {
        POINT pt;
        GetCursorPos(&pt);
        ReleaseCapture();
        SendMessageW(hwnd, WM_NCLBUTTONDOWN, HTCAPTION,
                     MAKELPARAM((short)pt.x, (short)pt.y));
    }
    return 1;
}

#endif /* _WIN32 */
