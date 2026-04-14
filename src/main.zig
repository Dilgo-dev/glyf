// glyf entry point.
// Boots the terminal, wires the platform layer, and hands off to the
// event loop. Everything non-trivial lives in sibling modules.

const std = @import("std");

pub fn main() !void {
    const stdout = std.io.getStdOut().writer();
    try stdout.print("glyf 0.0.0\n", .{});
}

test "smoke" {
    try std.testing.expect(true);
}
