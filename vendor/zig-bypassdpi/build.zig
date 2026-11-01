// Snapshot of debpalash/zig-bypassdpi at 4fad7f6b340c89ffdcee4845850e39d04766b628.
// Local Zig 0.17 adapter; replace with an upstream pin once available.
const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    const exe = b.addExecutable(.{
        .name = "zig-bypassdpi",
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/main.zig"),
            .target = target,
            .optimize = optimize,
        }),
    });
    b.installArtifact(exe);

    // `zig build run -- --port 8881 ...`
    const run_cmd = b.addRunArtifact(exe);
    run_cmd.step.dependOn(b.getInstallStep());
    run_cmd.addPassthruArgs();
    const run_step = b.step("run", "Build and run the proxy");
    run_step.dependOn(&run_cmd.step);

    // `zig build test` — runs the pure unit tests in desync.zig and socks.zig.
    const test_step = b.step("test", "Run unit tests");
    inline for (.{ "src/desync.zig", "src/socks.zig" }) |path| {
        const t = b.addTest(.{
            .root_module = b.createModule(.{
                .root_source_file = b.path(path),
                .target = target,
                .optimize = optimize,
            }),
        });
        test_step.dependOn(&b.addRunArtifact(t).step);
    }
}
