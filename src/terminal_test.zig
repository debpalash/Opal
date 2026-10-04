//! Test root for the embedded terminal: lives in src/ so the terminal files can
//! import from core/ inside one module.
test {
    _ = @import("terminal/pty.zig");
    _ = @import("terminal/session.zig");
    _ = @import("terminal/keymap.zig");
    _ = @import("terminal/pointer.zig");
}
