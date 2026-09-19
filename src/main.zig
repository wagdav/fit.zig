const std = @import("std");
const Io = std.Io;

const fit = @import("fit");
const Sport = fit.Types.Sport;

/// Activity summary — from the single `session` message.
const Summary = struct {
    sport: Sport,
    total_distance: f32,
    total_elapsed_time: f32,
};

/// A track point — from each `record` message. Positions are raw semicircles.
const Point = struct {
    position_lat: ?i32,
    position_long: ?i32,
    altitude: ?f16,
    heart_rate: ?u8,
};

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

    const MesgNum = std.meta.fieldInfo(fit.Message, .message_number).type;
    var discarded: std.EnumSet(MesgNum) = .initEmpty();

    var parser: fit.Parser = .init(in);
    var it = parser.messages();
    while (try it.next()) |msg| switch (msg.message_number) {
        .session => summary = try msg.decode(.session, Summary),
        .record => try track.append(gpa, try msg.decode(.record, Point)),
        else => discarded.insert(msg.message_number),
    };

    if (summary) |s| {
        try out.print("sport:      {?s}\n", .{std.enums.tagName(Sport, s.sport)});
        try out.print("distance:   {d:.2} km\n", .{s.total_distance / 1000.0});
        try out.print("elapsed:    {d:.0} s\n", .{s.total_elapsed_time});
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
    if (first) |a| try out.print("start:      {d:.5}, {d:.5}\n", .{
        fit.degrees(a.position_lat.?),
        fit.degrees(a.position_long.?),
    });
    if (last) |b| try out.print("end:        {d:.5}, {d:.5}\n", .{
        fit.degrees(b.position_lat.?),
        fit.degrees(b.position_long.?),
    });

    if (discarded.count() > 0) {
        try out.print("discarded:  ", .{});
        var first_discarded = true;
        var iter = discarded.iterator();
        while (iter.next()) |m| {
            if (!first_discarded) try out.print(", ", .{});
            first_discarded = false;
            if (std.enums.tagName(MesgNum, m)) |name| {
                try out.print("{s}", .{name});
            } else {
                try out.print("{d}", .{@intFromEnum(m)});
            }
        }
        try out.print("\n", .{});
    }

    try out.flush();
}
