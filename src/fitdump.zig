//! `fitdump` — read a FIT file from stdin and print its messages in the
//! readable format of python-fitparse's `fitdump` tool:
//!
//!     1. file_id
//!      * type: activity
//!      * manufacturer: 15
//!      * serial_number: 1234 [s]
//!
//!     2. record
//!      * heart_rate: 140 [bpm]
//!      * distance: 5.1 [m]
//!
//! It uses the dynamic `msg.fields()` iterator, so values are decoded against
//! the (subset) profile: scale/offset applied, enum tag names resolved,
//! unknown messages and fields printed as `unknown_<num>`. Values our profile
//! does not transform (e.g. timestamps, manufacturer ids) are printed raw, so
//! the output matches fitparse's *format* but not every value.

const std = @import("std");
const Io = std.Io;

const fit = @import("fit");
const MesgNum = fit.MesgNum;

pub fn main(init: std.process.Init) !void {
    const io = init.io;

    var stdin_buffer: [4096]u8 = undefined;
    var stdin_file_reader: Io.File.Reader = .init(.stdin(), io, &stdin_buffer);
    const in = &stdin_file_reader.interface;

    var stdout_buffer: [4096]u8 = undefined;
    var stdout_file_writer: Io.File.Writer = .init(.stdout(), io, &stdout_buffer);
    const out = &stdout_file_writer.interface;

    var parser: fit.Parser = .init(in);
    var it = parser.messages();

    var num: usize = 0;
    while (try it.next()) |msg| {
        num += 1;
        try printMessageName(out, num, msg.message_number);

        var fields = msg.fields();
        while (try fields.next()) |field| {
            try out.print(" * ", .{});
            if (field.name) |name| {
                try out.print("{s}", .{name});
            } else {
                try out.print("unknown_{d}", .{field.number});
            }
            try out.print(": ", .{});
            try printValue(out, field.value);
            if (field.units) |units| try out.print(" [{s}]", .{units});
            try out.print("\n", .{});
        }
        try out.print("\n", .{});
    }

    try out.flush();
}

fn printMessageName(out: *Io.Writer, num: usize, message_number: MesgNum) !void {
    if (std.enums.tagName(MesgNum, message_number)) |name| {
        try out.print("{d}. {s}\n", .{ num, name });
    } else {
        try out.print("{d}. unknown_{d}\n", .{ num, @intFromEnum(message_number) });
    }
}

fn printValue(out: *Io.Writer, value: fit.Value) !void {
    switch (value) {
        .uint => |u| try out.print("{d}", .{u}),
        .int => |i| try out.print("{d}", .{i}),
        .float => |f| try out.print("{d}", .{f}),
        .string => |s| try out.print("{s}", .{s}),
        .invalid => try out.print("None", .{}),
        .enum_tag => |e| {
            if (e.name) |name| {
                try out.print("{s}", .{name});
            } else {
                try out.print("{d}", .{e.value});
            }
        },
        .array => |a| {
            try out.print("[", .{});
            for (0..a.len()) |i| {
                if (i != 0) try out.print(", ", .{});
                try out.print("{d}", .{a.at(i)});
            }
            try out.print("]", .{});
        },
    }
}
