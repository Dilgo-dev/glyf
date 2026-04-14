//! Terminal grid model.
//!
//! A fixed-size row x col array of cells plus a cursor and a ring
//! buffer scrollback. Cells carry a codepoint and a Style. The grid
//! knows how to print a codepoint at the cursor, wrap at the right
//! edge, scroll up when the cursor falls off the bottom, and expose
//! scrolled-off rows through the scrollback.

const std = @import("std");

/// RGB / indexed / default color, as stored per cell foreground and
/// background. Indexed covers the 256-color palette.
pub const Color = union(enum) {
    default,
    indexed: u8,
    rgb: struct { r: u8, g: u8, b: u8 },

    pub fn eql(a: Color, b: Color) bool {
        return switch (a) {
            .default => b == .default,
            .indexed => |ai| b == .indexed and ai == b.indexed,
            .rgb => |ar| b == .rgb and ar.r == b.rgb.r and ar.g == b.rgb.g and ar.b == b.rgb.b,
        };
    }
};

/// SGR-level cell attributes.
pub const Style = struct {
    fg: Color = .default,
    bg: Color = .default,
    bold: bool = false,
    italic: bool = false,
    underline: bool = false,
    reverse: bool = false,

    pub fn eql(a: Style, b: Style) bool {
        return a.fg.eql(b.fg) and a.bg.eql(b.bg) and
            a.bold == b.bold and a.italic == b.italic and
            a.underline == b.underline and a.reverse == b.reverse;
    }
};

/// A single grid cell. Empty cells hold U+0020 and the default style.
pub const Cell = struct {
    codepoint: u21 = ' ',
    style: Style = .{},

    pub const empty: Cell = .{};
};

/// Cursor position plus the style that new cells inherit.
pub const Cursor = struct {
    row: u16 = 0,
    col: u16 = 0,
    style: Style = .{},
    /// True when the cursor sits past the last column, waiting for
    /// the next print to wrap to the next line. Matches the xterm
    /// "pending wrap" semantics.
    wrap_pending: bool = false,
};

/// Fixed-capacity ring buffer of scrolled-off rows.
/// Lines are stored as flat slices of `cols` cells. If the column
/// count of the parent grid changes, the scrollback is reset
/// (content reflow is a follow-up).
pub const Scrollback = struct {
    allocator: std.mem.Allocator,
    cells: []Cell,
    cols: u16,
    capacity: u32,
    /// Index of the oldest line (0..capacity).
    head: u32,
    /// Number of valid lines (0..capacity).
    count: u32,

    pub fn init(allocator: std.mem.Allocator, capacity: u32, cols: u16) !Scrollback {
        const cells = try allocator.alloc(Cell, @as(usize, capacity) * cols);
        @memset(cells, Cell.empty);
        return .{
            .allocator = allocator,
            .cells = cells,
            .cols = cols,
            .capacity = capacity,
            .head = 0,
            .count = 0,
        };
    }

    pub fn deinit(self: *Scrollback) void {
        self.allocator.free(self.cells);
        self.* = undefined;
    }

    /// Push a line at the tail. If the buffer is full, the oldest
    /// line is overwritten.
    pub fn push(self: *Scrollback, line: []const Cell) void {
        std.debug.assert(line.len == self.cols);
        if (self.capacity == 0) return;
        const index = (self.head + self.count) % self.capacity;
        const start = @as(usize, index) * self.cols;
        @memcpy(self.cells[start .. start + self.cols], line);
        if (self.count < self.capacity) {
            self.count += 1;
        } else {
            self.head = (self.head + 1) % self.capacity;
        }
    }

    /// Read the i-th scrollback line where 0 is the oldest and
    /// count-1 is the most recently pushed.
    pub fn get(self: Scrollback, i: u32) []const Cell {
        std.debug.assert(i < self.count);
        const index = (self.head + i) % self.capacity;
        const start = @as(usize, index) * self.cols;
        return self.cells[start .. start + self.cols];
    }
};

/// The main grid. Owns its cell buffer and scrollback.
pub const Grid = struct {
    allocator: std.mem.Allocator,
    rows: u16,
    cols: u16,
    cells: []Cell,
    cursor: Cursor,
    scrollback: Scrollback,

    /// Build a `rows`x`cols` grid with a scrollback of `scrollback`
    /// lines. All cells start empty and the cursor at 0, 0.
    pub fn init(
        allocator: std.mem.Allocator,
        rows: u16,
        cols: u16,
        scrollback: u32,
    ) !Grid {
        std.debug.assert(rows > 0 and cols > 0);
        const cells = try allocator.alloc(Cell, @as(usize, rows) * cols);
        @memset(cells, Cell.empty);
        const sb = try Scrollback.init(allocator, scrollback, cols);
        return .{
            .allocator = allocator,
            .rows = rows,
            .cols = cols,
            .cells = cells,
            .cursor = .{},
            .scrollback = sb,
        };
    }

    pub fn deinit(self: *Grid) void {
        self.allocator.free(self.cells);
        self.scrollback.deinit();
        self.* = undefined;
    }

    /// Read-only view of the cell at (row, col).
    pub fn cell(self: Grid, row: u16, col: u16) Cell {
        return self.cells[@as(usize, row) * self.cols + col];
    }

    /// Mutable pointer to the cell at (row, col).
    pub fn cellPtr(self: Grid, row: u16, col: u16) *Cell {
        return &self.cells[@as(usize, row) * self.cols + col];
    }

    /// Overwrite every cell with `Cell.empty` and reset the cursor.
    pub fn clear(self: *Grid) void {
        @memset(self.cells, Cell.empty);
        self.cursor = .{};
    }

    /// Move the cursor to (row, col), clamped to the grid size.
    pub fn setCursor(self: *Grid, row: u16, col: u16) void {
        self.cursor.row = @min(row, self.rows - 1);
        self.cursor.col = @min(col, self.cols - 1);
        self.cursor.wrap_pending = false;
    }

    /// Set the style applied to any cell the cursor writes next.
    pub fn setStyle(self: *Grid, style: Style) void {
        self.cursor.style = style;
    }

    /// Print a codepoint at the cursor position. Handles pending
    /// wrap, advances the cursor, and marks wrap at the right edge.
    pub fn print(self: *Grid, codepoint: u21) void {
        if (self.cursor.wrap_pending) {
            self.cursor.col = 0;
            self.lineFeed();
        }

        const ptr = self.cellPtr(self.cursor.row, self.cursor.col);
        ptr.codepoint = codepoint;
        ptr.style = self.cursor.style;

        if (self.cursor.col + 1 >= self.cols) {
            self.cursor.wrap_pending = true;
        } else {
            self.cursor.col += 1;
        }
    }

    /// Advance the cursor one row, scrolling up if we fall off the
    /// bottom. The column is left unchanged.
    pub fn lineFeed(self: *Grid) void {
        if (self.cursor.row + 1 >= self.rows) {
            self.scrollUp(1);
        } else {
            self.cursor.row += 1;
        }
        self.cursor.wrap_pending = false;
    }

    /// Move the cursor to column 0 of the current row.
    pub fn carriageReturn(self: *Grid) void {
        self.cursor.col = 0;
        self.cursor.wrap_pending = false;
    }

    /// Scroll the grid up by `n` rows. The top `n` rows are pushed
    /// into the scrollback, the remaining rows shift up, and the
    /// bottom `n` rows are cleared.
    pub fn scrollUp(self: *Grid, n: u16) void {
        const lines = @min(n, self.rows);
        const cols_usize = @as(usize, self.cols);

        var i: u16 = 0;
        while (i < lines) : (i += 1) {
            const start = @as(usize, i) * cols_usize;
            self.scrollback.push(self.cells[start .. start + cols_usize]);
        }

        const keep = self.rows - lines;
        if (keep > 0) {
            std.mem.copyForwards(
                Cell,
                self.cells[0 .. @as(usize, keep) * cols_usize],
                self.cells[@as(usize, lines) * cols_usize .. @as(usize, self.rows) * cols_usize],
            );
        }
        @memset(
            self.cells[@as(usize, keep) * cols_usize .. @as(usize, self.rows) * cols_usize],
            Cell.empty,
        );
    }

    /// Resize to `rows` x `cols`. Content in the overlap region is
    /// preserved. When `cols` changes, the scrollback is reset
    /// because its rows are stored at the old width.
    pub fn resize(self: *Grid, rows: u16, cols: u16) !void {
        std.debug.assert(rows > 0 and cols > 0);
        if (rows == self.rows and cols == self.cols) return;

        const new_cells = try self.allocator.alloc(Cell, @as(usize, rows) * cols);
        @memset(new_cells, Cell.empty);

        const copy_rows = @min(self.rows, rows);
        const copy_cols = @min(self.cols, cols);
        var r: u16 = 0;
        while (r < copy_rows) : (r += 1) {
            const src_start = @as(usize, r) * self.cols;
            const dst_start = @as(usize, r) * cols;
            @memcpy(
                new_cells[dst_start .. dst_start + copy_cols],
                self.cells[src_start .. src_start + copy_cols],
            );
        }

        self.allocator.free(self.cells);
        self.cells = new_cells;

        if (cols != self.cols) {
            const capacity = self.scrollback.capacity;
            self.scrollback.deinit();
            self.scrollback = try Scrollback.init(self.allocator, capacity, cols);
        }

        self.rows = rows;
        self.cols = cols;
        if (self.cursor.row >= rows) self.cursor.row = rows - 1;
        if (self.cursor.col >= cols) self.cursor.col = cols - 1;
        self.cursor.wrap_pending = false;
    }
};

// --------------------------- Tests ---------------------------------

const expect = std.testing.expect;
const expectEqual = std.testing.expectEqual;

test "init and deinit" {
    var g = try Grid.init(std.testing.allocator, 24, 80, 100);
    defer g.deinit();
    try expectEqual(@as(u16, 24), g.rows);
    try expectEqual(@as(u16, 80), g.cols);
    try expectEqual(@as(u21, ' '), g.cell(0, 0).codepoint);
    try expectEqual(@as(u21, ' '), g.cell(23, 79).codepoint);
}

test "print advances cursor" {
    var g = try Grid.init(std.testing.allocator, 5, 10, 10);
    defer g.deinit();
    g.print('h');
    g.print('i');
    try expectEqual(@as(u21, 'h'), g.cell(0, 0).codepoint);
    try expectEqual(@as(u21, 'i'), g.cell(0, 1).codepoint);
    try expectEqual(@as(u16, 2), g.cursor.col);
    try expectEqual(@as(u16, 0), g.cursor.row);
}

test "print wraps at end of row" {
    var g = try Grid.init(std.testing.allocator, 3, 3, 10);
    defer g.deinit();
    g.print('a');
    g.print('b');
    g.print('c');
    try expect(g.cursor.wrap_pending);
    g.print('d');
    try expectEqual(@as(u21, 'a'), g.cell(0, 0).codepoint);
    try expectEqual(@as(u21, 'b'), g.cell(0, 1).codepoint);
    try expectEqual(@as(u21, 'c'), g.cell(0, 2).codepoint);
    try expectEqual(@as(u21, 'd'), g.cell(1, 0).codepoint);
    try expectEqual(@as(u16, 1), g.cursor.row);
    try expectEqual(@as(u16, 1), g.cursor.col);
}

test "carriage return and line feed" {
    var g = try Grid.init(std.testing.allocator, 3, 5, 10);
    defer g.deinit();
    g.print('a');
    g.print('b');
    g.carriageReturn();
    try expectEqual(@as(u16, 0), g.cursor.col);
    g.lineFeed();
    try expectEqual(@as(u16, 1), g.cursor.row);
    try expectEqual(@as(u16, 0), g.cursor.col);
}

test "scroll up pushes top row to scrollback" {
    var g = try Grid.init(std.testing.allocator, 3, 3, 10);
    defer g.deinit();
    for (0..3) |c| g.cellPtr(0, @intCast(c)).codepoint = 'a';
    for (0..3) |c| g.cellPtr(1, @intCast(c)).codepoint = 'b';
    for (0..3) |c| g.cellPtr(2, @intCast(c)).codepoint = 'c';

    g.scrollUp(1);

    try expectEqual(@as(u21, 'b'), g.cell(0, 0).codepoint);
    try expectEqual(@as(u21, 'c'), g.cell(1, 0).codepoint);
    try expectEqual(@as(u21, ' '), g.cell(2, 0).codepoint);
    try expectEqual(@as(u32, 1), g.scrollback.count);
    try expectEqual(@as(u21, 'a'), g.scrollback.get(0)[0].codepoint);
}

test "scrollback ring overflow" {
    var g = try Grid.init(std.testing.allocator, 1, 2, 3);
    defer g.deinit();
    // Push 5 lines when capacity is 3.
    for (0..5) |i| {
        g.cellPtr(0, 0).codepoint = @intCast('a' + i);
        g.cellPtr(0, 1).codepoint = @intCast('a' + i);
        g.scrollUp(1);
    }
    try expectEqual(@as(u32, 3), g.scrollback.count);
    // The three oldest surviving lines are c, d, e.
    try expectEqual(@as(u21, 'c'), g.scrollback.get(0)[0].codepoint);
    try expectEqual(@as(u21, 'd'), g.scrollback.get(1)[0].codepoint);
    try expectEqual(@as(u21, 'e'), g.scrollback.get(2)[0].codepoint);
}

test "line feed at bottom scrolls up" {
    var g = try Grid.init(std.testing.allocator, 2, 2, 10);
    defer g.deinit();
    g.print('a');
    g.lineFeed();
    g.print('b');
    g.lineFeed();
    try expectEqual(@as(u16, 1), g.cursor.row);
    try expectEqual(@as(u21, ' '), g.cell(0, 0).codepoint);
    try expectEqual(@as(u21, 'b'), g.cell(0, 1).codepoint);
    try expectEqual(@as(u32, 1), g.scrollback.count);
}

test "set and clamp cursor" {
    var g = try Grid.init(std.testing.allocator, 3, 3, 10);
    defer g.deinit();
    g.setCursor(1, 1);
    try expectEqual(@as(u16, 1), g.cursor.row);
    try expectEqual(@as(u16, 1), g.cursor.col);
    g.setCursor(99, 99);
    try expectEqual(@as(u16, 2), g.cursor.row);
    try expectEqual(@as(u16, 2), g.cursor.col);
}

test "clear resets grid and cursor" {
    var g = try Grid.init(std.testing.allocator, 2, 2, 10);
    defer g.deinit();
    g.print('x');
    g.print('y');
    g.clear();
    try expectEqual(@as(u21, ' '), g.cell(0, 0).codepoint);
    try expectEqual(@as(u21, ' '), g.cell(0, 1).codepoint);
    try expectEqual(@as(u16, 0), g.cursor.row);
    try expectEqual(@as(u16, 0), g.cursor.col);
}

test "resize preserves overlap" {
    var g = try Grid.init(std.testing.allocator, 2, 2, 10);
    defer g.deinit();
    g.print('a');
    g.print('b');
    g.lineFeed();
    g.carriageReturn();
    g.print('c');
    g.print('d');
    try g.resize(3, 4);
    try expectEqual(@as(u16, 3), g.rows);
    try expectEqual(@as(u16, 4), g.cols);
    try expectEqual(@as(u21, 'a'), g.cell(0, 0).codepoint);
    try expectEqual(@as(u21, 'b'), g.cell(0, 1).codepoint);
    try expectEqual(@as(u21, 'c'), g.cell(1, 0).codepoint);
    try expectEqual(@as(u21, 'd'), g.cell(1, 1).codepoint);
    try expectEqual(@as(u21, ' '), g.cell(2, 0).codepoint);
    try expectEqual(@as(u21, ' '), g.cell(0, 2).codepoint);
}

test "style applies to printed cells" {
    var g = try Grid.init(std.testing.allocator, 2, 2, 10);
    defer g.deinit();
    g.setStyle(.{ .fg = .{ .indexed = 1 }, .bold = true });
    g.print('x');
    const c = g.cell(0, 0);
    try expectEqual(@as(u21, 'x'), c.codepoint);
    try expect(c.style.bold);
    try expect(c.style.fg.eql(.{ .indexed = 1 }));
    try expect(c.style.bg.eql(.default));
}
