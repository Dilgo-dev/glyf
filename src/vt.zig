//! VT parser.
//!
//! Byte-at-a-time implementation of Paul Williams' ANSI VT500 state
//! machine (https://vt100.net/emu/dec_ansi_parser). Translates a raw
//! terminal byte stream into semantic events: print, execute, CSI,
//! OSC, DCS, ESC.
//!
//! Parameterised at comptime by a Handler type. The Handler must
//! expose:
//!
//!   print(*Handler, u8)
//!   execute(*Handler, u8)
//!   csiDispatch(*Handler, []const u16, []const u8, u8)
//!   escDispatch(*Handler, []const u8, u8)
//!   oscDispatch(*Handler, []const u8)
//!   dcsHook(*Handler, []const u16, []const u8, u8)
//!   dcsPut(*Handler, u8)
//!   dcsUnhook(*Handler)
//!
//! The parser calls them synchronously as bytes are fed in.

const std = @import("std");

/// Maximum number of CSI/DCS numeric parameters the parser stores.
/// Extras overflow silently (spec allows truncation).
pub const max_params = 16;

/// Maximum number of intermediate bytes (0x20-0x2F) the parser stores.
/// Real sequences rarely use more than two.
pub const max_intermediates = 2;

/// OSC buffer capacity. OSC payloads longer than this are truncated.
pub const max_osc = 1024;

/// Parser states, mirroring Williams' FSM.
pub const State = enum {
    ground,
    escape,
    escape_intermediate,
    csi_entry,
    csi_param,
    csi_intermediate,
    csi_ignore,
    dcs_entry,
    dcs_param,
    dcs_intermediate,
    dcs_passthrough,
    dcs_ignore,
    osc_string,
    sos_pm_apc_string,
};

/// Build a Parser type bound to a Handler at comptime.
pub fn Parser(comptime Handler: type) type {
    return struct {
        const Self = @This();

        state: State = .ground,
        params: [max_params]u16 = [_]u16{0} ** max_params,
        params_len: u8 = 0,
        current_param: u32 = 0,
        param_started: bool = false,
        intermediates: [max_intermediates]u8 = [_]u8{0} ** max_intermediates,
        intermediates_len: u8 = 0,
        osc_buf: [max_osc]u8 = [_]u8{0} ** max_osc,
        osc_len: usize = 0,
        pending_dcs_final: u8 = 0,
        dcs_hook_pending: bool = false,

        /// Return a fresh parser in the ground state.
        pub fn init() Self {
            return .{};
        }

        /// Feed a slice of bytes into the parser.
        pub fn feed(self: *Self, handler: *Handler, bytes: []const u8) void {
            for (bytes) |b| self.advance(handler, b);
        }

        /// Feed a single byte into the parser.
        pub fn advance(self: *Self, handler: *Handler, byte: u8) void {
            // Anywhere transitions take precedence over state-specific bytes.
            switch (byte) {
                0x18, 0x1a => {
                    handler.execute(byte);
                    self.transition(handler, .ground);
                    return;
                },
                0x1b => {
                    self.transition(handler, .escape);
                    return;
                },
                else => {},
            }

            switch (self.state) {
                .ground => self.onGround(handler, byte),
                .escape => self.onEscape(handler, byte),
                .escape_intermediate => self.onEscapeIntermediate(handler, byte),
                .csi_entry => self.onCsiEntry(handler, byte),
                .csi_param => self.onCsiParam(handler, byte),
                .csi_intermediate => self.onCsiIntermediate(handler, byte),
                .csi_ignore => self.onCsiIgnore(handler, byte),
                .dcs_entry => self.onDcsEntry(handler, byte),
                .dcs_param => self.onDcsParam(handler, byte),
                .dcs_intermediate => self.onDcsIntermediate(handler, byte),
                .dcs_passthrough => self.onDcsPassthrough(handler, byte),
                .dcs_ignore => {},
                .osc_string => self.onOscString(handler, byte),
                .sos_pm_apc_string => {},
            }
        }

        fn transition(self: *Self, handler: *Handler, new_state: State) void {
            // Exit action of the old state.
            switch (self.state) {
                .osc_string => {
                    handler.oscDispatch(self.osc_buf[0..self.osc_len]);
                    self.osc_len = 0;
                },
                .dcs_passthrough => handler.dcsUnhook(),
                else => {},
            }

            self.state = new_state;

            // Entry action of the new state.
            switch (new_state) {
                .escape, .csi_entry, .dcs_entry => self.clear(),
                .osc_string => self.osc_len = 0,
                else => {},
            }
        }

        fn clear(self: *Self) void {
            self.params_len = 0;
            self.current_param = 0;
            self.param_started = false;
            self.intermediates_len = 0;
        }

        fn collect(self: *Self, byte: u8) void {
            if (self.intermediates_len < max_intermediates) {
                self.intermediates[self.intermediates_len] = byte;
                self.intermediates_len += 1;
            }
        }

        fn param(self: *Self, byte: u8) void {
            if (byte == ';') {
                self.commitParam();
                return;
            }
            if (byte == ':') {
                // Sub-parameter separator (xterm). Treated as a param
                // break for now; proper sub-param support is a follow-up.
                self.commitParam();
                return;
            }
            // Digit 0-9.
            if (self.params_len >= max_params) return;
            self.current_param = self.current_param *% 10 +% (byte - '0');
            self.param_started = true;
        }

        fn commitParam(self: *Self) void {
            if (self.params_len < max_params) {
                self.params[self.params_len] = @intCast(@min(self.current_param, std.math.maxInt(u16)));
                self.params_len += 1;
            }
            self.current_param = 0;
            self.param_started = false;
        }

        fn finalizeParams(self: *Self) void {
            if (self.param_started or self.params_len > 0) self.commitParam();
        }

        fn csiDispatch(self: *Self, handler: *Handler, final: u8) void {
            self.finalizeParams();
            handler.csiDispatch(
                self.params[0..self.params_len],
                self.intermediates[0..self.intermediates_len],
                final,
            );
        }

        fn escDispatch(self: *Self, handler: *Handler, final: u8) void {
            handler.escDispatch(self.intermediates[0..self.intermediates_len], final);
        }

        fn dcsHook(self: *Self, handler: *Handler, final: u8) void {
            self.finalizeParams();
            handler.dcsHook(
                self.params[0..self.params_len],
                self.intermediates[0..self.intermediates_len],
                final,
            );
        }

        fn oscPut(self: *Self, byte: u8) void {
            if (self.osc_len < max_osc) {
                self.osc_buf[self.osc_len] = byte;
                self.osc_len += 1;
            }
        }

        fn onGround(_: *Self, handler: *Handler, byte: u8) void {
            switch (byte) {
                0x00...0x17, 0x19, 0x1c...0x1f => handler.execute(byte),
                0x7f => {},
                else => handler.print(byte),
            }
        }

        fn onEscape(self: *Self, handler: *Handler, byte: u8) void {
            switch (byte) {
                0x00...0x17, 0x19, 0x1c...0x1f => handler.execute(byte),
                0x20...0x2f => {
                    self.collect(byte);
                    self.state = .escape_intermediate;
                },
                0x50 => self.transition(handler, .dcs_entry),
                0x58, 0x5e, 0x5f => self.state = .sos_pm_apc_string,
                0x5b => self.transition(handler, .csi_entry),
                0x5d => self.transition(handler, .osc_string),
                0x7f => {},
                else => {
                    self.escDispatch(handler, byte);
                    self.state = .ground;
                },
            }
        }

        fn onEscapeIntermediate(self: *Self, handler: *Handler, byte: u8) void {
            switch (byte) {
                0x00...0x17, 0x19, 0x1c...0x1f => handler.execute(byte),
                0x20...0x2f => self.collect(byte),
                0x7f => {},
                else => {
                    self.escDispatch(handler, byte);
                    self.state = .ground;
                },
            }
        }

        fn onCsiEntry(self: *Self, handler: *Handler, byte: u8) void {
            switch (byte) {
                0x00...0x17, 0x19, 0x1c...0x1f => handler.execute(byte),
                0x20...0x2f => {
                    self.collect(byte);
                    self.state = .csi_intermediate;
                },
                0x30...0x39, 0x3b => {
                    self.param(byte);
                    self.state = .csi_param;
                },
                0x3a => self.state = .csi_ignore,
                0x3c...0x3f => {
                    self.collect(byte);
                    self.state = .csi_param;
                },
                0x40...0x7e => {
                    self.csiDispatch(handler, byte);
                    self.state = .ground;
                },
                0x7f => {},
                else => {},
            }
        }

        fn onCsiParam(self: *Self, handler: *Handler, byte: u8) void {
            switch (byte) {
                0x00...0x17, 0x19, 0x1c...0x1f => handler.execute(byte),
                0x30...0x39, 0x3b => self.param(byte),
                0x3a, 0x3c...0x3f => self.state = .csi_ignore,
                0x20...0x2f => {
                    self.collect(byte);
                    self.state = .csi_intermediate;
                },
                0x40...0x7e => {
                    self.csiDispatch(handler, byte);
                    self.state = .ground;
                },
                0x7f => {},
                else => {},
            }
        }

        fn onCsiIntermediate(self: *Self, handler: *Handler, byte: u8) void {
            switch (byte) {
                0x00...0x17, 0x19, 0x1c...0x1f => handler.execute(byte),
                0x20...0x2f => self.collect(byte),
                0x30...0x3f => self.state = .csi_ignore,
                0x40...0x7e => {
                    self.csiDispatch(handler, byte);
                    self.state = .ground;
                },
                0x7f => {},
                else => {},
            }
        }

        fn onCsiIgnore(self: *Self, handler: *Handler, byte: u8) void {
            switch (byte) {
                0x00...0x17, 0x19, 0x1c...0x1f => handler.execute(byte),
                0x40...0x7e => self.state = .ground,
                else => {},
            }
        }

        fn onDcsEntry(self: *Self, _: *Handler, byte: u8) void {
            switch (byte) {
                0x20...0x2f => {
                    self.collect(byte);
                    self.state = .dcs_intermediate;
                },
                0x30...0x39, 0x3b => {
                    self.param(byte);
                    self.state = .dcs_param;
                },
                0x3a => self.state = .dcs_ignore,
                0x3c...0x3f => {
                    self.collect(byte);
                    self.state = .dcs_param;
                },
                0x40...0x7e => self.enterDcsPassthrough(byte),
                else => {},
            }
        }

        fn onDcsParam(self: *Self, _: *Handler, byte: u8) void {
            switch (byte) {
                0x30...0x39, 0x3b => self.param(byte),
                0x3a, 0x3c...0x3f => self.state = .dcs_ignore,
                0x20...0x2f => {
                    self.collect(byte);
                    self.state = .dcs_intermediate;
                },
                0x40...0x7e => self.enterDcsPassthrough(byte),
                else => {},
            }
        }

        fn onDcsIntermediate(self: *Self, _: *Handler, byte: u8) void {
            switch (byte) {
                0x20...0x2f => self.collect(byte),
                0x30...0x3f => self.state = .dcs_ignore,
                0x40...0x7e => self.enterDcsPassthrough(byte),
                else => {},
            }
        }

        fn enterDcsPassthrough(self: *Self, byte: u8) void {
            // We do not use transition() here because dcs_passthrough's
            // hook action needs the final byte, which is byte itself.
            // The hook is called on behalf of the future handler when
            // advance() resumes in dcs_passthrough.
            self.pending_dcs_final = byte;
            self.state = .dcs_passthrough;
            self.dcs_hook_pending = true;
        }

        fn onDcsPassthrough(self: *Self, handler: *Handler, byte: u8) void {
            if (self.dcs_hook_pending) {
                self.dcsHook(handler, self.pending_dcs_final);
                self.dcs_hook_pending = false;
            }
            switch (byte) {
                0x00...0x17, 0x19, 0x1c...0x1f, 0x20...0x7e => handler.dcsPut(byte),
                0x7f => {},
                else => {},
            }
        }

        fn onOscString(self: *Self, handler: *Handler, byte: u8) void {
            switch (byte) {
                0x07 => {
                    // xterm convention: BEL terminates OSC.
                    self.transition(handler, .ground);
                },
                0x20...0xff => self.oscPut(byte),
                else => {},
            }
        }
    };
}

// --------------------------- Tests ---------------------------------

const TestHandler = struct {
    events: std.ArrayList(Event),
    allocator: std.mem.Allocator,

    pub const Event = union(enum) {
        print: u8,
        execute: u8,
        csi: Csi,
        esc: Esc,
        osc: []u8,
        dcs_hook: Csi,
        dcs_put: u8,
        dcs_unhook: void,
    };

    pub const Csi = struct {
        params: [max_params]u16 = [_]u16{0} ** max_params,
        params_len: u8 = 0,
        intermediates: [max_intermediates]u8 = [_]u8{0} ** max_intermediates,
        intermediates_len: u8 = 0,
        final: u8 = 0,
    };

    pub const Esc = struct {
        intermediates: [max_intermediates]u8 = [_]u8{0} ** max_intermediates,
        intermediates_len: u8 = 0,
        final: u8 = 0,
    };

    pub fn init(allocator: std.mem.Allocator) TestHandler {
        return .{ .events = .{}, .allocator = allocator };
    }

    pub fn deinit(self: *TestHandler) void {
        for (self.events.items) |ev| {
            if (ev == .osc) self.allocator.free(ev.osc);
        }
        self.events.deinit(self.allocator);
    }

    pub fn print(self: *TestHandler, byte: u8) void {
        self.events.append(self.allocator, .{ .print = byte }) catch {};
    }

    pub fn execute(self: *TestHandler, byte: u8) void {
        self.events.append(self.allocator, .{ .execute = byte }) catch {};
    }

    pub fn csiDispatch(self: *TestHandler, params: []const u16, intermediates: []const u8, final: u8) void {
        var csi = Csi{ .final = final };
        for (params, 0..) |p, i| csi.params[i] = p;
        csi.params_len = @intCast(params.len);
        for (intermediates, 0..) |b, i| csi.intermediates[i] = b;
        csi.intermediates_len = @intCast(intermediates.len);
        self.events.append(self.allocator, .{ .csi = csi }) catch {};
    }

    pub fn escDispatch(self: *TestHandler, intermediates: []const u8, final: u8) void {
        var esc = Esc{ .final = final };
        for (intermediates, 0..) |b, i| esc.intermediates[i] = b;
        esc.intermediates_len = @intCast(intermediates.len);
        self.events.append(self.allocator, .{ .esc = esc }) catch {};
    }

    pub fn oscDispatch(self: *TestHandler, data: []const u8) void {
        const copy = self.allocator.dupe(u8, data) catch return;
        self.events.append(self.allocator, .{ .osc = copy }) catch {};
    }

    pub fn dcsHook(self: *TestHandler, params: []const u16, intermediates: []const u8, final: u8) void {
        var csi = Csi{ .final = final };
        for (params, 0..) |p, i| csi.params[i] = p;
        csi.params_len = @intCast(params.len);
        for (intermediates, 0..) |b, i| csi.intermediates[i] = b;
        csi.intermediates_len = @intCast(intermediates.len);
        self.events.append(self.allocator, .{ .dcs_hook = csi }) catch {};
    }

    pub fn dcsPut(self: *TestHandler, byte: u8) void {
        self.events.append(self.allocator, .{ .dcs_put = byte }) catch {};
    }

    pub fn dcsUnhook(self: *TestHandler) void {
        self.events.append(self.allocator, .{ .dcs_unhook = {} }) catch {};
    }
};

const P = Parser(TestHandler);

test "print plain ascii" {
    var h = TestHandler.init(std.testing.allocator);
    defer h.deinit();
    var p = P.init();
    p.feed(&h, "hi");
    try std.testing.expectEqual(@as(usize, 2), h.events.items.len);
    try std.testing.expectEqual(@as(u8, 'h'), h.events.items[0].print);
    try std.testing.expectEqual(@as(u8, 'i'), h.events.items[1].print);
}

test "execute control chars" {
    var h = TestHandler.init(std.testing.allocator);
    defer h.deinit();
    var p = P.init();
    p.feed(&h, "\x07\x0a\x0d");
    try std.testing.expectEqual(@as(usize, 3), h.events.items.len);
    try std.testing.expectEqual(@as(u8, 0x07), h.events.items[0].execute);
    try std.testing.expectEqual(@as(u8, 0x0a), h.events.items[1].execute);
    try std.testing.expectEqual(@as(u8, 0x0d), h.events.items[2].execute);
}

test "csi no params" {
    var h = TestHandler.init(std.testing.allocator);
    defer h.deinit();
    var p = P.init();
    p.feed(&h, "\x1b[H");
    try std.testing.expectEqual(@as(usize, 1), h.events.items.len);
    const csi = h.events.items[0].csi;
    try std.testing.expectEqual(@as(u8, 'H'), csi.final);
    try std.testing.expectEqual(@as(u8, 0), csi.params_len);
    try std.testing.expectEqual(@as(u8, 0), csi.intermediates_len);
}

test "csi multiple params" {
    var h = TestHandler.init(std.testing.allocator);
    defer h.deinit();
    var p = P.init();
    p.feed(&h, "\x1b[10;20;30H");
    const csi = h.events.items[0].csi;
    try std.testing.expectEqual(@as(u8, 'H'), csi.final);
    try std.testing.expectEqual(@as(u8, 3), csi.params_len);
    try std.testing.expectEqual(@as(u16, 10), csi.params[0]);
    try std.testing.expectEqual(@as(u16, 20), csi.params[1]);
    try std.testing.expectEqual(@as(u16, 30), csi.params[2]);
}

test "csi private marker and param" {
    var h = TestHandler.init(std.testing.allocator);
    defer h.deinit();
    var p = P.init();
    p.feed(&h, "\x1b[?25h");
    const csi = h.events.items[0].csi;
    try std.testing.expectEqual(@as(u8, 'h'), csi.final);
    try std.testing.expectEqual(@as(u8, 1), csi.intermediates_len);
    try std.testing.expectEqual(@as(u8, '?'), csi.intermediates[0]);
    try std.testing.expectEqual(@as(u8, 1), csi.params_len);
    try std.testing.expectEqual(@as(u16, 25), csi.params[0]);
}

test "osc bel terminated" {
    var h = TestHandler.init(std.testing.allocator);
    defer h.deinit();
    var p = P.init();
    p.feed(&h, "\x1b]0;title\x07");
    try std.testing.expectEqual(@as(usize, 1), h.events.items.len);
    try std.testing.expectEqualStrings("0;title", h.events.items[0].osc);
}

test "osc st terminated" {
    var h = TestHandler.init(std.testing.allocator);
    defer h.deinit();
    var p = P.init();
    p.feed(&h, "\x1b]2;window\x1b\\");
    // OSC emits osc on exit; the trailing \ generates a spurious esc
    // dispatch for 0x5c which tests should tolerate.
    try std.testing.expect(h.events.items.len >= 1);
    try std.testing.expectEqualStrings("2;window", h.events.items[0].osc);
}

test "esc dispatch simple" {
    var h = TestHandler.init(std.testing.allocator);
    defer h.deinit();
    var p = P.init();
    p.feed(&h, "\x1b7");
    try std.testing.expectEqual(@as(usize, 1), h.events.items.len);
    try std.testing.expectEqual(@as(u8, '7'), h.events.items[0].esc.final);
}

test "esc dispatch with intermediate" {
    var h = TestHandler.init(std.testing.allocator);
    defer h.deinit();
    var p = P.init();
    p.feed(&h, "\x1b(B");
    const esc = h.events.items[0].esc;
    try std.testing.expectEqual(@as(u8, 'B'), esc.final);
    try std.testing.expectEqual(@as(u8, 1), esc.intermediates_len);
    try std.testing.expectEqual(@as(u8, '('), esc.intermediates[0]);
}

test "dcs hook, put, unhook" {
    var h = TestHandler.init(std.testing.allocator);
    defer h.deinit();
    var p = P.init();
    p.feed(&h, "\x1bP1;2|abc\x1b\\");
    // Expected: dcs_hook, dcs_put*3, dcs_unhook, optional esc for '\\'.
    try std.testing.expect(h.events.items.len >= 5);
    try std.testing.expectEqual(@as(u8, '|'), h.events.items[0].dcs_hook.final);
    try std.testing.expectEqual(@as(u8, 2), h.events.items[0].dcs_hook.params_len);
    try std.testing.expectEqual(@as(u8, 'a'), h.events.items[1].dcs_put);
    try std.testing.expectEqual(@as(u8, 'b'), h.events.items[2].dcs_put);
    try std.testing.expectEqual(@as(u8, 'c'), h.events.items[3].dcs_put);
    try std.testing.expectEqual(@as(void, {}), h.events.items[4].dcs_unhook);
}

test "print then csi then print" {
    var h = TestHandler.init(std.testing.allocator);
    defer h.deinit();
    var p = P.init();
    p.feed(&h, "a\x1b[31mb");
    try std.testing.expectEqual(@as(usize, 3), h.events.items.len);
    try std.testing.expectEqual(@as(u8, 'a'), h.events.items[0].print);
    try std.testing.expectEqual(@as(u8, 'm'), h.events.items[1].csi.final);
    try std.testing.expectEqual(@as(u16, 31), h.events.items[1].csi.params[0]);
    try std.testing.expectEqual(@as(u8, 'b'), h.events.items[2].print);
}
