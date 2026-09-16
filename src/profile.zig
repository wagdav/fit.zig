//! The FIT Global Profile, as comptime tables.
//!
//! Hand-written for now (a subset); the shape is the stable interface and can
//! later be generated from Garmin's `Profile.xlsx`. Each message is a
//! `[]const RawField`, and `MesgNum` maps message names to their global numbers.
//! See docs/interface-design.md.

const std = @import("std");
const types = @import("types.zig");

/// A single field of a message: its definition number, name, and the decoded
/// target type. For scalar fields the type is the carrier type (the Zig
/// integer/float the wire value maps to); for enumerated fields it is the
/// generated enum. No unit conversion is baked in — see the conversion policy.
const RawField = struct {
    number: u8,
    name: []const u8,
    type: type,
};

/// Global message number. Non-exhaustive: any unrecognized number decodes to an
/// unnamed value, which a `switch (msg.message_number)` handles via `else`.
pub const MesgNum = enum(u16) {
    file_id = 0,
    session = 18,
    record = 20,
    field_description = 206,
    developer_data_id = 207,
    _,
};

const file_id: []const RawField = &.{
    .{ .number = 0, .name = "type", .type = types.File },
    .{ .number = 1, .name = "manufacturer", .type = u16 },
    .{ .number = 2, .name = "product", .type = u16 },
    .{ .number = 3, .name = "serial_number", .type = u32 },
    .{ .number = 4, .name = "time_created", .type = u32 }, // date_time carrier
    .{ .number = 5, .name = "number", .type = u16 },
    .{ .number = 8, .name = "product_name", .type = [16]u8 },
};

const session: []const RawField = &.{
    .{ .number = 253, .name = "timestamp", .type = u32 }, // date_time carrier
    .{ .number = 5, .name = "sport", .type = types.Sport },
    .{ .number = 7, .name = "total_elapsed_time", .type = u32 },
    .{ .number = 8, .name = "total_timer_time", .type = u32 },
    .{ .number = 9, .name = "total_distance", .type = u32 },
};

const record: []const RawField = &.{
    .{ .number = 253, .name = "timestamp", .type = u32 }, // date_time carrier
    .{ .number = 0, .name = "position_lat", .type = i32 }, // semicircles carrier
    .{ .number = 1, .name = "position_long", .type = i32 },
    .{ .number = 2, .name = "altitude", .type = u16 },
    .{ .number = 3, .name = "heart_rate", .type = u8 },
    .{ .number = 4, .name = "cadence", .type = u8 },
    .{ .number = 5, .name = "distance", .type = u32 },
    .{ .number = 6, .name = "speed", .type = u16 },
};

/// The fields of a message, resolved at comptime from its `MesgNum` tag.
fn fields(comptime message_number: MesgNum) []const RawField {
    return @field(@This(), @tagName(message_number));
}

/// Look up a single field of a message by name. Raises `@compileError` when the
/// name is not part of the message — this is the guard against a view struct
/// whose fields don't belong to the message number it is decoded against.
pub fn field(comptime message_number: MesgNum, comptime name: []const u8) RawField {
    inline for (fields(message_number)) |f| {
        if (comptime std.mem.eql(u8, f.name, name)) return f;
    }
    @compileError("no field '" ++ name ++ "' on message " ++ @tagName(message_number));
}
