//! Windows ConPTY implementation.
//!
//! Creates a pseudoconsole via CreatePseudoConsole, wires two anonymous
//! pipes for stdin and stdout, and spawns a child with
//! PROC_THREAD_ATTRIBUTE_PSEUDOCONSOLE set on the startup info.

const std = @import("std");
const builtin = @import("builtin");
const windows = std.os.windows;

comptime {
    if (builtin.os.tag != .windows) {
        @compileError("pty_windows module is windows-only");
    }
}

const HANDLE = windows.HANDLE;
const HRESULT = windows.HRESULT;
const DWORD = windows.DWORD;
const BOOL = windows.BOOL;

const HPCON = *opaque {};

const COORD = extern struct {
    X: i16,
    Y: i16,
};

const INFINITE: DWORD = 0xFFFFFFFF;
const FALSE: BOOL = 0;

extern "kernel32" fn CreatePseudoConsole(
    size: COORD,
    hInput: HANDLE,
    hOutput: HANDLE,
    dwFlags: DWORD,
    phPC: *HPCON,
) callconv(.winapi) HRESULT;

extern "kernel32" fn ResizePseudoConsole(
    hPC: HPCON,
    size: COORD,
) callconv(.winapi) HRESULT;

extern "kernel32" fn ClosePseudoConsole(hPC: HPCON) callconv(.winapi) void;

extern "kernel32" fn CreatePipe(
    hReadPipe: *HANDLE,
    hWritePipe: *HANDLE,
    lpPipeAttributes: ?*windows.SECURITY_ATTRIBUTES,
    nSize: DWORD,
) callconv(.winapi) BOOL;

extern "kernel32" fn CloseHandle(hObject: HANDLE) callconv(.winapi) BOOL;

extern "kernel32" fn ReadFile(
    hFile: HANDLE,
    lpBuffer: [*]u8,
    nNumberOfBytesToRead: DWORD,
    lpNumberOfBytesRead: *DWORD,
    lpOverlapped: ?*anyopaque,
) callconv(.winapi) BOOL;

extern "kernel32" fn WriteFile(
    hFile: HANDLE,
    lpBuffer: [*]const u8,
    nNumberOfBytesToWrite: DWORD,
    lpNumberOfBytesWritten: *DWORD,
    lpOverlapped: ?*anyopaque,
) callconv(.winapi) BOOL;

extern "kernel32" fn InitializeProcThreadAttributeList(
    lpAttributeList: ?[*]u8,
    dwAttributeCount: DWORD,
    dwFlags: DWORD,
    lpSize: *usize,
) callconv(.winapi) BOOL;

extern "kernel32" fn UpdateProcThreadAttribute(
    lpAttributeList: [*]u8,
    dwFlags: DWORD,
    Attribute: usize,
    lpValue: *anyopaque,
    cbSize: usize,
    lpPreviousValue: ?*anyopaque,
    lpReturnSize: ?*usize,
) callconv(.winapi) BOOL;

extern "kernel32" fn DeleteProcThreadAttributeList(
    lpAttributeList: [*]u8,
) callconv(.winapi) void;

extern "kernel32" fn CreateProcessW(
    lpApplicationName: ?[*:0]const u16,
    lpCommandLine: ?[*:0]u16,
    lpProcessAttributes: ?*windows.SECURITY_ATTRIBUTES,
    lpThreadAttributes: ?*windows.SECURITY_ATTRIBUTES,
    bInheritHandles: BOOL,
    dwCreationFlags: DWORD,
    lpEnvironment: ?*anyopaque,
    lpCurrentDirectory: ?[*:0]const u16,
    lpStartupInfo: *STARTUPINFOEXW,
    lpProcessInformation: *windows.PROCESS_INFORMATION,
) callconv(.winapi) BOOL;

extern "kernel32" fn WaitForSingleObject(
    hHandle: HANDLE,
    dwMilliseconds: DWORD,
) callconv(.winapi) DWORD;

extern "kernel32" fn GetExitCodeProcess(
    hProcess: HANDLE,
    lpExitCode: *DWORD,
) callconv(.winapi) BOOL;

const STARTUPINFOEXW = extern struct {
    StartupInfo: windows.STARTUPINFOW,
    lpAttributeList: ?[*]u8,
};

const PROC_THREAD_ATTRIBUTE_PSEUDOCONSOLE: usize = 0x00020016;
const EXTENDED_STARTUPINFO_PRESENT: DWORD = 0x00080000;

pub const Error = error{
    PipeFailed,
    CreatePseudoConsoleFailed,
    AttributeListFailed,
    CreateProcessFailed,
    SetSizeFailed,
    ReadFailed,
    WriteFailed,
    Utf16ConversionFailed,
    ArgvEmpty,
    OutOfMemory,
};

/// Window size in rows and columns.
pub const Size = struct { rows: u16, cols: u16 };

/// Windows ConPTY handle plus the two pipes the emulator talks through.
pub const Pty = struct {
    hpc: HPCON,
    /// Read end of the child's stdout pipe.
    read_handle: HANDLE,
    /// Write end of the child's stdin pipe.
    write_handle: HANDLE,
    size: Size,

    /// Open a new PTY pair with a default 24x80 size. Use setSize to
    /// adjust immediately after if a different size is needed.
    pub fn open() Error!Pty {
        return openWithSize(.{ .rows = 24, .cols = 80 });
    }

    fn openWithSize(size: Size) Error!Pty {
        var in_read: HANDLE = undefined;
        var in_write: HANDLE = undefined;
        if (CreatePipe(&in_read, &in_write, null, 0) == 0) {
            return Error.PipeFailed;
        }

        var out_read: HANDLE = undefined;
        var out_write: HANDLE = undefined;
        if (CreatePipe(&out_read, &out_write, null, 0) == 0) {
            _ = CloseHandle(in_read);
            _ = CloseHandle(in_write);
            return Error.PipeFailed;
        }

        const coord = COORD{
            .X = @intCast(size.cols),
            .Y = @intCast(size.rows),
        };
        var hpc: HPCON = undefined;
        const hr = CreatePseudoConsole(coord, in_read, out_write, 0, &hpc);

        _ = CloseHandle(in_read);
        _ = CloseHandle(out_write);

        if (hr < 0) {
            _ = CloseHandle(in_write);
            _ = CloseHandle(out_read);
            return Error.CreatePseudoConsoleFailed;
        }

        return .{
            .hpc = hpc,
            .read_handle = out_read,
            .write_handle = in_write,
            .size = size,
        };
    }

    /// Close the pseudoconsole and both pipe handles.
    pub fn deinit(self: *Pty) void {
        ClosePseudoConsole(self.hpc);
        _ = CloseHandle(self.read_handle);
        _ = CloseHandle(self.write_handle);
        self.* = undefined;
    }

    /// Resize the pseudoconsole.
    pub fn setSize(self: *Pty, size: Size) Error!void {
        const coord = COORD{
            .X = @intCast(size.cols),
            .Y = @intCast(size.rows),
        };
        const hr = ResizePseudoConsole(self.hpc, coord);
        if (hr < 0) return Error.SetSizeFailed;
        self.size = size;
    }

    /// Read bytes produced by the child.
    pub fn read(self: Pty, buf: []u8) Error!usize {
        var n: DWORD = 0;
        if (ReadFile(self.read_handle, buf.ptr, @intCast(buf.len), &n, null) == 0) {
            return Error.ReadFailed;
        }
        return @intCast(n);
    }

    /// Write bytes to the child's stdin.
    pub fn write(self: Pty, buf: []const u8) Error!usize {
        var n: DWORD = 0;
        if (WriteFile(self.write_handle, buf.ptr, @intCast(buf.len), &n, null) == 0) {
            return Error.WriteFailed;
        }
        return @intCast(n);
    }

    /// Spawn a child attached to the pseudoconsole. argv elements are
    /// joined with spaces to form the command line. Callers with
    /// spaces in arguments must pre-quote per MSVCRT rules.
    pub fn spawn(
        self: *Pty,
        allocator: std.mem.Allocator,
        argv: []const []const u8,
    ) Error!Child {
        if (argv.len == 0) return Error.ArgvEmpty;

        var arena = std.heap.ArenaAllocator.init(allocator);
        defer arena.deinit();
        const a = arena.allocator();

        var cmdline = std.ArrayList(u8){};
        for (argv, 0..) |arg, i| {
            if (i > 0) cmdline.append(a, ' ') catch return Error.OutOfMemory;
            cmdline.appendSlice(a, arg) catch return Error.OutOfMemory;
        }

        const cmdline_w = std.unicode.utf8ToUtf16LeAllocZ(a, cmdline.items) catch
            return Error.Utf16ConversionFailed;

        var attr_list_size: usize = 0;
        _ = InitializeProcThreadAttributeList(null, 1, 0, &attr_list_size);
        const attr_list = a.alloc(u8, attr_list_size) catch return Error.OutOfMemory;

        if (InitializeProcThreadAttributeList(attr_list.ptr, 1, 0, &attr_list_size) == 0) {
            return Error.AttributeListFailed;
        }
        defer DeleteProcThreadAttributeList(attr_list.ptr);

        if (UpdateProcThreadAttribute(
            attr_list.ptr,
            0,
            PROC_THREAD_ATTRIBUTE_PSEUDOCONSOLE,
            @ptrCast(self.hpc),
            @sizeOf(HPCON),
            null,
            null,
        ) == 0) {
            return Error.AttributeListFailed;
        }

        var si: STARTUPINFOEXW = std.mem.zeroes(STARTUPINFOEXW);
        si.StartupInfo.cb = @sizeOf(STARTUPINFOEXW);
        si.lpAttributeList = attr_list.ptr;

        var pi: windows.PROCESS_INFORMATION = undefined;

        if (CreateProcessW(
            null,
            cmdline_w,
            null,
            null,
            FALSE,
            EXTENDED_STARTUPINFO_PRESENT,
            null,
            null,
            &si,
            &pi,
        ) == 0) {
            return Error.CreateProcessFailed;
        }

        _ = CloseHandle(pi.hThread);
        return .{ .process = pi.hProcess };
    }
};

/// A spawned child process attached to a ConPTY.
pub const Child = struct {
    process: HANDLE,

    /// Wait for the child to exit and return its exit code.
    pub fn wait(self: Child) u32 {
        _ = WaitForSingleObject(self.process, INFINITE);
        var code: DWORD = 0;
        _ = GetExitCodeProcess(self.process, &code);
        _ = CloseHandle(self.process);
        return @intCast(code);
    }
};

test "open, set size, close" {
    var pty = try Pty.open();
    defer pty.deinit();
    try pty.setSize(.{ .rows = 30, .cols = 100 });
}

test "spawn cmd echo reads output" {
    var pty = try Pty.open();
    defer pty.deinit();

    const argv = [_][]const u8{ "cmd.exe", "/c", "echo hello-pty" };
    const child = try pty.spawn(std.testing.allocator, &argv);

    var buf: [512]u8 = undefined;
    const n = pty.read(&buf) catch 0;
    _ = child.wait();
    try std.testing.expect(n > 0);
    try std.testing.expect(std.mem.indexOf(u8, buf[0..n], "hello-pty") != null);
}
