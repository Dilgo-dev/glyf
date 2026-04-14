// glyf entry point.
// Boots the terminal, wires the platform layer, and hands off to the
// event loop. Everything non-trivial lives in sibling modules.

const std = @import("std");
const pty = @import("pty.zig");

pub fn main() !void {
    std.debug.print("glyf 0.0.0\n", .{});

    var p = try pty.Pty.open();
    defer p.deinit();
    try p.setSize(.{ .rows = 24, .cols = 80 });
    std.debug.print("pty opened (24x80)\n", .{});
}

test "smoke" {
    try std.testing.expect(true);
}
