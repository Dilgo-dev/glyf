//! Cross-platform PTY abstraction.
//!
//! Routes to a posix implementation (posix_openpt + fork + execvp) or
//! a windows implementation (ConPTY) based on the target OS. Both
//! expose the same public API: open, deinit, setSize, read, write,
//! spawn, and Child.wait.

const std = @import("std");
const builtin = @import("builtin");

const impl = if (builtin.os.tag == .windows)
    @import("pty_windows.zig")
else
    @import("pty_posix.zig");

/// Window size in rows and columns.
pub const Size = impl.Size;
/// Errors raised by the PTY API. Values differ per platform.
pub const Error = impl.Error;
/// PTY handle. Platform-specific fields, common methods.
pub const Pty = impl.Pty;
/// Handle to a spawned child process.
pub const Child = impl.Child;

test {
    _ = impl;
}
