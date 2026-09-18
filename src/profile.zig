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
/// generated enum.
const RawField = struct {
    number: u8,
    name: []const u8,
    type: type,
    scale: ?comptime_int,
    offset: ?comptime_int,
    units: ?[]const u8,
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
    .{ .number = 0, .name = "type", .type = types.File, .scale = null, .offset = null, .units = null },
    .{ .number = 1, .name = "manufacturer", .type = u16, .scale = null, .offset = null, .units = null },
    .{ .number = 2, .name = "product", .type = u16, .scale = null, .offset = null, .units = null },
    .{ .number = 3, .name = "serial_number", .type = u32, .scale = null, .offset = null, .units = null },
    .{ .number = 4, .name = "time_created", .type = u32, .scale = null, .offset = null, .units = null }, // date_time carrier
    .{ .number = 5, .name = "number", .type = u16, .scale = null, .offset = null, .units = null },
    .{ .number = 8, .name = "product_name", .type = [16]u8, .scale = null, .offset = null, .units = null },
};

const session: []const RawField = &.{
    .{ .number = 253, .name = "timestamp", .type = u32, .scale = null, .offset = null, .units = "s" }, // date_time carrier
    .{ .number = 5, .name = "sport", .type = types.Sport, .scale = null, .offset = null, .units = null },
    .{ .number = 7, .name = "total_elapsed_time", .type = u32, .scale = 1000, .offset = null, .units = "s" },
    .{ .number = 8, .name = "total_timer_time", .type = u32, .scale = 1000, .offset = null, .units = "s" },
    .{ .number = 9, .name = "total_distance", .type = u32, .scale = 100, .offset = null, .units = "m" },
};

const record: []const RawField = &.{
    .{ .number = 253, .name = "timestamp", .type = u32, .scale = null, .offset = null, .units = "s" }, // date_time carrier
    .{ .number = 0, .name = "position_lat", .type = i32, .scale = null, .offset = null, .units = "semicircles" }, // semicircles carrier
    .{ .number = 1, .name = "position_long", .type = i32, .scale = null, .offset = null, .units = "semicircles" },
    .{ .number = 2, .name = "altitude", .type = u16, .scale = 5, .offset = 500, .units = "m" },
    .{ .number = 3, .name = "heart_rate", .type = u8, .scale = null, .offset = null, .units = "bpm" },
    .{ .number = 4, .name = "cadence", .type = u8, .scale = null, .offset = null, .units = null },
    .{ .number = 5, .name = "distance", .type = u32, .scale = 100, .offset = null, .units = "m" },
    .{ .number = 6, .name = "speed", .type = u16, .scale = 1000, .offset = null, .units = "m/s" },
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

/// Whether a field's scale/offset conversion requires its decoded target to be
/// a float. Any field with a scale or an offset produces a non-integral
/// quantity once converted (see the Scale/Offset comment in `root.zig`), so
/// the view struct's field type must be a float — assigning into an integer
/// would silently truncate or, worse, underflow when subtracting the offset.
pub fn needsFloatTarget(f: RawField) bool {
    return f.scale != null or f.offset != null;
}

const testing = std.testing;

test "needsFloatTarget matches known scaled/offset fields" {
    // Fields with scale and/or offset: must require a float target.
    try testing.expect(needsFloatTarget(field(.record, "altitude")));
    try testing.expect(needsFloatTarget(field(.record, "distance")));
    try testing.expect(needsFloatTarget(field(.record, "speed")));
    try testing.expect(needsFloatTarget(field(.session, "total_elapsed_time")));
    try testing.expect(needsFloatTarget(field(.session, "total_timer_time")));
    try testing.expect(needsFloatTarget(field(.session, "total_distance")));

    // Fields with neither: must not require a float target.
    try testing.expect(!needsFloatTarget(field(.record, "heart_rate")));
    try testing.expect(!needsFloatTarget(field(.record, "cadence")));
    try testing.expect(!needsFloatTarget(field(.record, "position_lat")));
    try testing.expect(!needsFloatTarget(field(.record, "timestamp")));
    try testing.expect(!needsFloatTarget(field(.session, "sport")));
    try testing.expect(!needsFloatTarget(field(.file_id, "manufacturer")));
}
