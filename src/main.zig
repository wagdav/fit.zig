const std = @import("std");
const Io = std.Io;

const fit = @import("fit_zig");

/// Activity summary — from the single `session` message. Fields are optional so
/// a file missing any of them still decodes. Scale is applied here by the caller
/// (the library returns raw carrier values): distance is centimetres, elapsed
/// time is milliseconds.
const Summary = struct {
    sport: fit.Sport,
    total_distance: u32,
    total_elapsed_time: u32,
};

/// A track point — from each `record` message. Positions are raw semicircles.
const Point = struct {
    position_lat: ?i32,
    position_long: ?i32,
    altitude: ?u16,
    heart_rate: ?u8,
};

fn degrees(semicircles: i32) f64 {
    return @as(f64, @floatFromInt(semicircles)) * (180.0 / 2147483648.0);
}

pub fn main(init: std.process.Init) !void {
    const io = init.io;
    const gpa = std.heap.page_allocator;

    var stdin_buffer: [4096]u8 = undefined;
    var stdin_file_reader: Io.File.Reader = .init(.stdin(), io, &stdin_buffer);
    const in = &stdin_file_reader.interface;

    var stdout_buffer: [4096]u8 = undefined;
    var stdout_file_writer: Io.File.Writer = .init(.stdout(), io, &stdout_buffer);
    const out = &stdout_file_writer.interface;

    // The parser is zero-alloc; the track is the caller's, one streaming pass.
    var track: std.ArrayList(Point) = .empty;
    defer track.deinit(gpa);
    var summary: ?Summary = null;

    var parser: fit.Parser = .init(in);
    var it = parser.messages();
    while (try it.next()) |msg| switch (msg.message_number) {
        .session => summary = try msg.decode(.session, Summary),
        .record => try track.append(gpa, try msg.decode(.record, Point)),
        else => {}, // everything else auto-skips
    };

    if (summary) |s| {
        try out.print("sport:      {}\n", .{s.sport});
        try out.print("distance:   {d:.2} km\n", .{@as(f64, @floatFromInt(s.total_distance)) / 100_000.0});
        try out.print("elapsed:    {d:.0} s\n", .{@as(f64, @floatFromInt(s.total_elapsed_time)) / 1000.0});
    } else {
        try out.print("(no session message)\n", .{});
    }

    var with_gps: usize = 0;
    var first: ?Point = null;
    var last: ?Point = null;
    for (track.items) |p| {
        if (p.position_lat != null and p.position_long != null) {
            with_gps += 1;
            if (first == null) first = p;
            last = p;
        }
    }
    try out.print("records:    {d} ({d} with GPS)\n", .{ track.items.len, with_gps });
    if (first) |a| try out.print("start:      {d:.5}, {d:.5}\n", .{ degrees(a.position_lat.?), degrees(a.position_long.?) });
    if (last) |b| try out.print("end:        {d:.5}, {d:.5}\n", .{ degrees(b.position_lat.?), degrees(b.position_long.?) });

    try out.flush();
}
