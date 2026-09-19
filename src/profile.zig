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
    scale: ?comptime_int = null,
    offset: ?comptime_int = null,
    units: ?[]const u8 = null,
};

/// Global message number. Non-exhaustive: any unrecognized number decodes to an
/// unnamed value, which a `switch (msg.message_number)` handles via `else`.
pub const MesgNum = enum(u16) {
    file_id = 0,
    capabilities = 1,
    device_settings = 2,
    user_profile = 3,
    zones_target = 7,
    sport = 12,
    training_settings = 13,
    session = 18,
    lap = 19,
    record = 20,
    event = 21,
    device_info = 23,
    activity = 34,
    training_file = 72,
    field_description = 206,
    developer_data_id = 207,
    time_in_zone = 216,
    climb_pro = 317,
    device_aux_battery_info = 375,
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
    .{ .number = 253, .name = "timestamp", .type = u32, .units = "s" }, // date_time carrier
    .{ .number = 5, .name = "sport", .type = types.Sport },
    .{ .number = 7, .name = "total_elapsed_time", .type = u32, .scale = 1000, .units = "s" },
    .{ .number = 8, .name = "total_timer_time", .type = u32, .scale = 1000, .units = "s" },
    .{ .number = 9, .name = "total_distance", .type = u32, .scale = 100, .units = "m" },
};

const record: []const RawField = &.{
    .{ .number = 253, .name = "timestamp", .type = u32, .units = "s" }, // date_time carrier
    .{ .number = 0, .name = "position_lat", .type = i32, .units = "semicircles" }, // semicircles carrier
    .{ .number = 1, .name = "position_long", .type = i32, .units = "semicircles" },
    .{ .number = 2, .name = "altitude", .type = u16, .scale = 5, .offset = 500, .units = "m" },
    .{ .number = 3, .name = "heart_rate", .type = u8, .units = "bpm" },
    .{ .number = 4, .name = "cadence", .type = u8 },
    .{ .number = 5, .name = "distance", .type = u32, .scale = 100, .units = "m" },
    .{ .number = 6, .name = "speed", .type = u16, .scale = 1000, .units = "m/s" },
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

/// Runtime-facing metadata for a single field, resolved from the comptime
/// tables for the dynamic `msg.fields()` path. Unlike `RawField` it carries no
/// `type` (a `type` is not a runtime value); an enum field instead carries
/// `enumName`, a function mapping a raw wire value to its tag name.
pub const FieldInfo = struct {
    number: u8,
    name: []const u8,
    units: ?[]const u8,
    scale: ?f64,
    offset: ?f64,
    /// For enum-typed fields: maps a raw wire value to its tag name (null when
    /// the value is not a named tag). null for non-enum fields.
    enumName: ?*const fn (u64) ?[]const u8,
};

/// A comptime-generated namer for an enum value type. `name` maps a raw wire
/// value to its tag name, or null when the value is out of range / unnamed.
fn Namer(comptime E: type) type {
    return struct {
        fn name(raw: u64) ?[]const u8 {
            const e = std.enums.fromInt(E, raw) orelse return null;
            return std.enums.tagName(E, e);
        }
    };
}

/// Lower a comptime `RawField` (which holds a `type`) to runtime `FieldInfo`.
fn infoOf(comptime f: RawField) FieldInfo {
    return .{
        .number = f.number,
        .name = f.name,
        .units = f.units,
        .scale = if (f.scale) |s| @floatFromInt(s) else null,
        .offset = if (f.offset) |o| @floatFromInt(o) else null,
        .enumName = if (@typeInfo(f.type) == .@"enum") &Namer(f.type).name else null,
    };
}

/// Look up field metadata for a message at runtime, for the dynamic
/// `msg.fields()` path. Returns null when the message has no profile table or
/// no field with `number` (an unknown field the caller yields with `name` null).
///
/// The set of profiled messages is derived from the tables themselves: a
/// message has a table iff there is a decl named after its `MesgNum` tag, so
/// adding a `[]const RawField` is all it takes — no list to keep in sync here.
pub fn lookup(message_number: MesgNum, number: u8) ?FieldInfo {
    inline for (@typeInfo(MesgNum).@"enum".fields) |tag| {
        if (comptime @hasDecl(@This(), tag.name)) {
            if (message_number == @field(MesgNum, tag.name)) {
                inline for (comptime fields(@field(MesgNum, tag.name))) |f| {
                    if (f.number == number) return infoOf(f);
                }
                return null;
            }
        }
    }
    return null;
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
