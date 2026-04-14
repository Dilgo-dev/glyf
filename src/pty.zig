//! Posix PTY abstraction.
//!
//! Opens a controller/follower pair via posix_openpt + grantpt +
//! unlockpt + ptsname_r. Spawns a child with the follower as its
//! controlling terminal. Callers read and write on the controller fd.

const std = @import("std");
const builtin = @import("builtin");
const posix = std.posix;

comptime {
    if (builtin.os.tag == .windows) {
        @compileError("pty module is posix-only; windows uses conpty");
    }
}

extern "c" fn posix_openpt(flags: c_int) c_int;
extern "c" fn grantpt(fd: c_int) c_int;
extern "c" fn unlockpt(fd: c_int) c_int;
extern "c" fn ptsname_r(fd: c_int, buf: [*]u8, buflen: usize) c_int;
extern "c" fn execvp(file: [*:0]const u8, argv: [*:null]const ?[*:0]const u8) c_int;
extern "c" fn setsid() c_int;
extern "c" fn ioctl(fd: c_int, request: c_ulong, ...) c_int;

const Winsize = extern struct {
    ws_row: u16,
    ws_col: u16,
    ws_xpixel: u16,
    ws_ypixel: u16,
};

const TIOCSWINSZ: c_ulong = switch (builtin.os.tag) {
    .linux => 0x5414,
    .macos, .ios, .tvos, .watchos => 0x80087467,
    .freebsd, .netbsd, .openbsd, .dragonfly => 0x80087467,
    else => @compileError("unsupported os for TIOCSWINSZ"),
};

const TIOCSCTTY: c_ulong = switch (builtin.os.tag) {
    .linux => 0x540E,
    .macos, .ios, .tvos, .watchos => 0x20007461,
    .freebsd, .netbsd, .openbsd, .dragonfly => 0x20007461,
    else => @compileError("unsupported os for TIOCSCTTY"),
};

pub const Error = error{
    OpenFailed,
    GrantFailed,
    UnlockFailed,
    NameFailed,
    FollowerOpenFailed,
    SetSizeFailed,
    ForkFailed,
};

/// Window size in rows and columns.
pub const Size = struct {
    rows: u16,
    cols: u16,
};

/// Posix PTY controller/follower pair.
///
/// `controller` is the fd the terminal emulator reads and writes on.
/// `follower` is the fd the child process receives as its controlling
/// terminal (stdin, stdout, stderr).
pub const Pty = struct {
    controller: posix.fd_t,
    follower: posix.fd_t,

    /// Open a new PTY pair. On success the caller owns both fds.
    pub fn open() Error!Pty {
        const flags: c_int = @bitCast(posix.O{ .ACCMODE = .RDWR, .NOCTTY = true });
        const controller = posix_openpt(flags);
        if (controller < 0) return Error.OpenFailed;
        errdefer posix.close(controller);

        if (grantpt(controller) != 0) return Error.GrantFailed;
        if (unlockpt(controller) != 0) return Error.UnlockFailed;

        var name_buf: [128]u8 = undefined;
        if (ptsname_r(controller, &name_buf, name_buf.len) != 0) {
            return Error.NameFailed;
        }
        _ = std.mem.indexOfScalar(u8, &name_buf, 0) orelse return Error.NameFailed;
        const follower_path: [*:0]const u8 = @ptrCast(&name_buf);

        const follower = posix.openZ(
            follower_path,
            .{ .ACCMODE = .RDWR, .NOCTTY = true },
            0,
        ) catch return Error.FollowerOpenFailed;

        return .{ .controller = controller, .follower = follower };
    }

    /// Close both fds. Safe to call multiple times.
    pub fn deinit(self: *Pty) void {
        if (self.controller >= 0) {
            posix.close(self.controller);
            self.controller = -1;
        }
        if (self.follower >= 0) {
            posix.close(self.follower);
            self.follower = -1;
        }
    }

    /// Set the window size reported by the PTY.
    pub fn setSize(self: Pty, size: Size) Error!void {
        const ws = Winsize{
            .ws_row = size.rows,
            .ws_col = size.cols,
            .ws_xpixel = 0,
            .ws_ypixel = 0,
        };
        if (ioctl(self.controller, TIOCSWINSZ, &ws) != 0) {
            return Error.SetSizeFailed;
        }
    }

    /// Spawn a child attached to the follower as its controlling
    /// terminal. argv is a null-terminated array of null-terminated
    /// strings where argv[0] is the program name. On success the
    /// parent-side follower fd is closed.
    pub fn spawn(
        self: *Pty,
        file: [*:0]const u8,
        argv: [*:null]const ?[*:0]const u8,
    ) Error!Child {
        const pid = std.c.fork();
        if (pid < 0) return Error.ForkFailed;

        if (pid == 0) {
            childSetup(self.follower, self.controller);
            _ = execvp(file, argv);
            std.process.exit(127);
        }

        posix.close(self.follower);
        self.follower = -1;
        return .{ .pid = pid };
    }
};

fn childSetup(follower: posix.fd_t, controller: posix.fd_t) void {
    _ = setsid();
    _ = ioctl(follower, TIOCSCTTY, @as(c_int, 0));
    posix.dup2(follower, 0) catch std.process.exit(127);
    posix.dup2(follower, 1) catch std.process.exit(127);
    posix.dup2(follower, 2) catch std.process.exit(127);
    if (follower > 2) posix.close(follower);
    if (controller >= 0) posix.close(controller);
}

/// A spawned child process attached to a PTY.
pub const Child = struct {
    pid: posix.pid_t,

    /// Wait for the child to exit and return its raw status.
    pub fn wait(self: Child) u32 {
        const result = posix.waitpid(self.pid, 0);
        return result.status;
    }
};

test "open, set size, close" {
    var pty = try Pty.open();
    defer pty.deinit();
    try std.testing.expect(pty.controller >= 0);
    try std.testing.expect(pty.follower >= 0);
    try pty.setSize(.{ .rows = 24, .cols = 80 });
}

test "spawn echo reads output" {
    var pty = try Pty.open();
    defer pty.deinit();

    const argv = [_:null]?[*:0]const u8{ "echo", "hello-pty" };
    const child = try pty.spawn("echo", &argv);

    var buf: [256]u8 = undefined;
    const n = posix.read(pty.controller, &buf) catch 0;
    _ = child.wait();
    try std.testing.expect(n > 0);
    try std.testing.expect(std.mem.indexOf(u8, buf[0..n], "hello-pty") != null);
}
