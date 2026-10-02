//! Root-path test wrapper for the production YouTube projection and text helper.
const std = @import("std");
test {
    std.testing.refAllDecls(@import("services/remote_youtube_pure.zig"));
}
