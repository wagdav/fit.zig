//! Lookup helpers over the generated FIT profile tables in `profile.generated.zig`.
//! See docs/interface-design.md.

const std = @import("std");
const generated = @import("profile.generated.zig");

pub const MesgNum = generated.MesgNum;
pub const types = generated.types;
pub const version = generated.version;
pub const version_type = generated.version_type;

/// A single field of a message: its definition number, name, and the decoded
/// target type. For scalar fields the type is the carrier type (the Zig
/// integer/float the wire value maps to); for enumerated fields it is the
/// generated enum.
pub const RawField = struct {
    number: u8,
    name: []const u8,
    type: type,
    scale: ?comptime_float = null,
    offset: ?comptime_float = null,
    units: ?[]const u8 = null,
};

/// The fields of a message, resolved at comptime from its `MesgNum` tag.
fn fields(comptime message_number: MesgNum) []const RawField {
    return @field(generated, @tagName(message_number));
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
        .scale = if (f.scale) |s| @as(f64, s) else null,
        .offset = if (f.offset) |o| @as(f64, o) else null,
        .enumName = if (@typeInfo(f.type) == .@"enum") &Namer(f.type).name else null,
    };
}

/// The runtime field metadata of a message, built once at comptime.
fn infoTable(comptime message_number: MesgNum) []const FieldInfo {
    return &struct {
        const table = blk: {
            const raw = fields(message_number);
            var t: [raw.len]FieldInfo = undefined;
            for (raw, &t) |f, *info| info.* = infoOf(f);
            break :blk t;
        };
    }.table;
}

/// Look up field metadata for a message at runtime, for the dynamic
/// `msg.fields()` path. Returns null for a message number the profile does not
/// name, or a field number the message does not define (an unknown field the
/// caller yields with `name` null).
pub fn lookup(message_number: MesgNum, number: u8) ?FieldInfo {
    const table = switch (message_number) {
        inline else => |m| infoTable(m),
        _ => return null,
    };
    for (table) |info| if (info.number == number) return info;
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
