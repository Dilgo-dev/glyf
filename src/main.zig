// glyf entry point.
// Boots the terminal, wires the platform layer, and hands off to the
// event loop. Everything non-trivial lives in sibling modules.

const std = @import("std");
const builtin = @import("builtin");

pub fn main() !void {
    std.debug.print("glyf 0.0.0\n", .{});

    if (builtin.os.tag == .windows) {
        std.debug.print("pty: windows not supported yet\n", .{});
        return;
    }

    try posixDemo();
}

fn posixDemo() !void {
    const pty = @import("pty.zig");
    var p = try pty.Pty.open();
    defer p.deinit();
    try p.setSize(.{ .rows = 24, .cols = 80 });
    std.debug.print("pty: controller={d} follower={d}\n", .{ p.controller, p.follower });
}

test "smoke" {
    try std.testing.expect(true);
}
