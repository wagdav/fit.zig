//! A zero-allocation, streaming FIT file parser.
//! See https://developer.garmin.com/fit/protocol/
const std = @import("std");
const assert = std.debug.assert;
const Endian = std.builtin.Endian;
const Reader = std.Io.Reader;
const testing = std.testing;
const Struct = std.lang.Type.Struct;

const profile = @import("profile.zig");
pub const MesgNum = profile.MesgNum;
pub const Types = profile.types;
/// Version of the FIT Global Profile the tables were generated from.
pub const global_profile_version = profile.version;

pub const FitError = error{
    InvalidHeader,
    InvalidMagic,
    InvalidArchitecture,
    InvalidBaseType,
    /// A data message refers to a local message type with no prior definition.
    UndefinedLocalMessage,
    CompressedTimestampUnsupported,
    /// A view-struct field's wire arity did not match its target type.
    ArityMismatch,
    /// A field's wire base type is incompatible with its target type.
    BaseTypeMismatch,
    /// A wire value does not fit in its view-struct target type.
    ValueOutOfRange,
    /// A required (non-optional) view-struct field was absent or invalid.
    MissingField,
};

/// Information about the FIT File
/// See Table 1 of https://developer.garmin.com/fit/protocol/
const FileHeader = struct {
    size: u8,
    protocol_version: u8,
    profile_version: u16,
    data_size: u32,
    data_type: [4]u8,
    crc: u16,
};

/// The record header indicates whether the record content contains a
/// definition message, a normal data message or a compressed timestamp data
/// message. The record header also has a Local Message Type field that
/// references the local message in the data record to its global FIT message.
const RecordHeader = union(enum) {
    normal: Normal,
    compressed_timestamp: CompressedTimestamp,

    /// See Table 2 of https://developer.garmin.com/fit/protocol/
    const Normal = packed struct(u8) {
        local_message_type: u4,
        reserved: u1,
        has_developer_data: bool,
        is_definition: bool,
        header_type: Type,
    };

    /// See Table 3 of https://developer.garmin.com/fit/protocol/
    const CompressedTimestamp = packed struct(u8) {
        time_offset: u5,
        local_message_type: u2,
        header_type: Type,
    };

    const Type = enum(u1) {
        normal = 0,
        compressed_timestamp = 1,
    };

    fn decode(raw: u8) RecordHeader {
        const normal: Normal = @bitCast(raw);
        return switch (normal.header_type) {
            .normal => .{ .normal = normal },
            .compressed_timestamp => .{ .compressed_timestamp = @bitCast(raw) },
        };
    }
};

/// Local message types are 4 bits wide.
const max_definitions = 16;
/// Field counts are single bytes on the wire.
const max_fields = std.math.maxInt(u8);

/// See Table 4 of https://developer.garmin.com/fit/protocol/
const DefinitionMessage = struct {
    endian: Endian,
    message_number: MesgNum,
    num_fields: u8,
    field_buffer: [max_fields]FieldDefinition,
    /// Total size of the developer fields. They are skipped, never decoded:
    /// their base type lives in a `field_description` message the parser does
    /// not track.
    developer_data_size: u16,

    fn fields(def: *const DefinitionMessage) []const FieldDefinition {
        return def.field_buffer[0..def.num_fields];
    }

    /// Total number of payload bytes a data message of this definition occupies.
    fn payloadSize(def: *const DefinitionMessage) u32 {
        var n: u32 = def.developer_data_size;
        for (def.fields()) |f| n += f.size;
        return n;
    }

    fn hasField(def: *const DefinitionMessage, number: u8) bool {
        for (def.fields()) |f| {
            if (f.field_definition_number == number) return true;
        }
        return false;
    }
};

/// See Table 5 of https://developer.garmin.com/fit/protocol/
const FieldDefinition = struct {
    field_definition_number: u8,
    size: u8,
    base_type: BaseType,
};

/// See Table 6 of https://developer.garmin.com/fit/protocol/
pub const BaseType = enum(u8) {
    enum_ = 0x00,
    sint8 = 0x01,
    uint8 = 0x02,
    sint16 = 0x83,
    uint16 = 0x84,
    sint32 = 0x85,
    uint32 = 0x86,
    string = 0x07,
    float32 = 0x88,
    float64 = 0x89,
    uint8z = 0x0A,
    uint16z = 0x8B,
    uint32z = 0x8C,
    byte = 0x0D,
    sint64 = 0x8E,
    uint64 = 0x8F,
    uint64z = 0x90,

    /// Bytes per element.
    fn size(self: BaseType) u8 {
        return switch (self) {
            .enum_, .sint8, .uint8, .string, .uint8z, .byte => 1,
            .sint16, .uint16, .uint16z => 2,
            .sint32, .uint32, .float32, .uint32z => 4,
            .float64, .sint64, .uint64, .uint64z => 8,
        };
    }

    /// The bit pattern that indicates the field is not set.
    /// See Table 7 of https://developer.garmin.com/fit/protocol/
    fn invalid(self: BaseType) u64 {
        return switch (self) {
            .sint8 => 0x7F,
            .enum_, .uint8, .byte => 0xFF,
            .string, .uint8z, .uint16z, .uint32z, .uint64z => 0x00,
            .sint16 => 0x7FFF,
            .uint16 => 0xFFFF,
            .sint32 => 0x7FFFFFFF,
            .uint32, .float32 => 0xFFFFFFFF,
            .sint64 => 0x7FFFFFFFFFFFFFFF,
            .uint64, .float64 => 0xFFFFFFFFFFFFFFFF,
        };
    }
};

fn endian(arch: u8) !Endian {
    return switch (arch) {
        0 => .little,
        1 => .big,
        else => FitError.InvalidArchitecture,
    };
}

/// A raw wire scalar, widened to a size-independent representation.
const Raw = union(enum) {
    u: u64,
    i: i64,
    f: f64,

    fn toF64(raw: Raw) f64 {
        return switch (raw) {
            .u => |u| @floatFromInt(u),
            .i => |i| @floatFromInt(i),
            .f => |f| f,
        };
    }
};

/// Decode one scalar from exactly `base.size()` wire bytes. Returns `null` on
/// the invalid sentinel. Asserts `base` is not `.string`: strings are not
/// scalars, and callers handle them before getting here.
fn readRaw(bytes: []const u8, base: BaseType, en: Endian) ?Raw {
    assert(bytes.len == base.size());
    return switch (base) {
        .enum_, .uint8, .uint8z, .byte => readRawAs(u8, bytes, base, en),
        .uint16, .uint16z => readRawAs(u16, bytes, base, en),
        .uint32, .uint32z => readRawAs(u32, bytes, base, en),
        .uint64, .uint64z => readRawAs(u64, bytes, base, en),
        .sint8 => readRawAs(i8, bytes, base, en),
        .sint16 => readRawAs(i16, bytes, base, en),
        .sint32 => readRawAs(i32, bytes, base, en),
        .sint64 => readRawAs(i64, bytes, base, en),
        .float32 => readRawAs(f32, bytes, base, en),
        .float64 => readRawAs(f64, bytes, base, en),
        .string => unreachable,
    };
}

fn readRawAs(comptime T: type, bytes: []const u8, base: BaseType, en: Endian) ?Raw {
    const bits = std.mem.readInt(@Int(.unsigned, @bitSizeOf(T)), bytes[0..@sizeOf(T)], en);
    if (bits == base.invalid()) return null;
    const value: T = @bitCast(bits);
    return switch (@typeInfo(T)) {
        .int => |int| switch (int.signedness) {
            .unsigned => .{ .u = value },
            .signed => .{ .i = value },
        },
        .float => .{ .f = value },
        else => comptime unreachable,
    };
}

/// Apply a field's scale/offset to a value: divide by scale, then subtract
/// offset (see the FIT Scale/Offset rule). A no-op when both are null.
fn applyScaleOffset(v: f64, scale: ?f64, offset: ?f64) f64 {
    var out = v;
    if (scale) |s| out /= s;
    if (offset) |o| out -= o;
    return out;
}

// ------------------------------------------------------- dynamic decoding ---

/// A single decoded field of a message, yielded by `FieldIterator`. `name` and
/// `units` come from the profile and are null for a field the profile does not
/// describe (an unknown or developer-defined field number).
pub const Field = struct {
    number: u8,
    name: ?[]const u8,
    units: ?[]const u8,
    value: Value,
};

/// A decoded field value. Mirrors the typed `decode` path: scale/offset are
/// applied (yielding `float`), enum fields resolve their tag `name`, and
/// semicircle positions stay raw. `string`/`array` bytes point into the reader
/// buffer and are valid only until the next `FieldIterator.next()`.
pub const Value = union(enum) {
    uint: u64,
    int: i64,
    float: f64,
    enum_tag: EnumTag,
    string: []const u8,
    array: Array,
    /// The field is present but carries the FIT invalid sentinel.
    invalid,

    fn decode(bytes: []const u8, base: BaseType, en: Endian, info: ?profile.FieldInfo) Value {
        const scale = if (info) |i| i.scale else null;
        const offset = if (info) |i| i.offset else null;

        if (base == .string) return .{ .string = std.mem.sliceTo(bytes, 0) };
        if (bytes.len != base.size()) return .{ .array = .{
            .bytes = bytes,
            .base = base,
            .endian = en,
            .scale = scale,
            .offset = offset,
        } };

        const raw = readRaw(bytes, base, en) orelse return .invalid;
        if (info) |i| if (i.enumName) |name| switch (raw) {
            .u => |u| return .{ .enum_tag = .{ .value = u, .name = name(u) } },
            .i, .f => {}, // not a valid tag: report the plain value
        };
        if (scale != null or offset != null) return .{ .float = applyScaleOffset(raw.toF64(), scale, offset) };
        return switch (raw) {
            .u => |u| .{ .uint = u },
            .i => |i| .{ .int = i },
            .f => |f| .{ .float = f },
        };
    }
};

pub const EnumTag = struct {
    /// The raw wire value.
    value: u64,
    /// Its tag name, or null when the value is not a named tag.
    name: ?[]const u8,
};

/// A multi-value field. Elements are decoded on demand from `bytes` (no
/// allocation); `bytes` is valid only until the next `FieldIterator.next()`.
pub const Array = struct {
    bytes: []const u8,
    base: BaseType,
    endian: Endian,
    scale: ?f64,
    offset: ?f64,

    /// Number of elements.
    pub fn len(self: Array) usize {
        return self.bytes.len / self.base.size();
    }

    /// Decode element `i` to `f64`, applying any scale/offset. Asserts
    /// `i < len()`. An element carrying the invalid sentinel decodes to NaN.
    pub fn at(self: Array, i: usize) f64 {
        assert(i < self.len());
        const sz = self.base.size();
        const raw = readRaw(self.bytes[i * sz ..][0..sz], self.base, self.endian) orelse
            return std.math.nan(f64);
        return applyScaleOffset(raw.toF64(), self.scale, self.offset);
    }
};

/// Walk every (non-developer) field of a message in wire order, decoding each
/// against the profile — the dynamic counterpart to the typed `decode(m, T)`.
pub const FieldIterator = struct {
    parser: *Parser,
    def: *const DefinitionMessage,
    index: u8 = 0,

    pub fn next(self: *FieldIterator) !?Field {
        // Developer fields are not yielded; the parser skips them.
        if (self.index == self.def.num_fields) return null;
        const fdef = self.def.fields()[self.index];
        self.index += 1;

        const bytes = try self.parser.takeField(fdef);
        const info = profile.lookup(self.def.message_number, fdef.field_definition_number);
        return .{
            .number = fdef.field_definition_number,
            .name = if (info) |i| i.name else null,
            .units = if (info) |i| i.units else null,
            .value = .decode(bytes, fdef.base_type, self.def.endian, info),
        };
    }
};

// --------------------------------------------------------- typed decoding ---

/// `T` with any outer optional stripped (`?u32 -> u32`, `u32 -> u32`).
fn StripOptional(comptime T: type) type {
    return switch (@typeInfo(T)) {
        .optional => |o| o.child,
        else => T,
    };
}

/// A view-struct field is required when it is non-optional and has no default:
/// it must be filled from the wire, or `decode` fails.
fn isRequired(comptime FieldType: type, attrs: Struct.FieldAttributes) bool {
    return attrs.defaultValue(FieldType) == null and @typeInfo(FieldType) != .optional;
}

/// Assign the wire field `fdef` (whose payload is `bytes`) to the matching
/// field of `out`, if any.
fn assignField(
    comptime m: MesgNum,
    comptime T: type,
    out: *T,
    fdef: FieldDefinition,
    bytes: []const u8,
    en: Endian,
) !void {
    const info = @typeInfo(T).@"struct";
    inline for (info.field_names, info.field_types, info.field_attrs) |field_name, field_type, field_attr| {
        const field = comptime profile.field(m, field_name);
        const Target = StripOptional(field_type);

        // Scale/Offset: when specified, the binary quantity is divided by the
        // scale factor and then the offset is subtracted, yielding a floating
        // point quantity.
        if (comptime profile.needsFloatTarget(field) and @typeInfo(Target) != .float)
            @compileError(@typeName(T) ++ "." ++ field_name ++ " should be float because the field uses scale/offset.");

        if (fdef.field_definition_number == field.number) {
            var value = (try readField(Target, fdef, bytes, en)) orelse {
                if (comptime isRequired(field_type, field_attr)) return FitError.MissingField;
                return; // optional stays null, defaulted keeps its default
            };
            if (field.scale) |scale| value /= scale;
            if (field.offset) |offset| value -= offset;
            @field(out, field_name) = value;
            return;
        }
    }
}

/// Decode one view-struct field from its wire bytes. Returns `null` when the
/// field carries the FIT invalid sentinel.
fn readField(comptime T: type, fdef: FieldDefinition, bytes: []const u8, en: Endian) !?T {
    assert(bytes.len == fdef.size);
    const base = fdef.base_type;
    switch (@typeInfo(T)) {
        .int, .float, .@"enum" => {
            if (fdef.size != base.size()) return FitError.ArityMismatch;
            return readScalar(T, bytes, base, en);
        },
        .array => |arr| {
            if (arr.child == u8 and (base == .string or base == .byte)) {
                // Truncated to fit `T`, zero-padded.
                const text = std.mem.sliceTo(bytes, 0);
                var out: T = @splat(0);
                const n = @min(out.len, text.len);
                @memcpy(out[0..n], text[0..n]);
                return out;
            }
            if (fdef.size != base.size() * arr.len) return FitError.ArityMismatch;
            const sz = base.size();
            var out: T = undefined;
            for (&out, 0..) |*slot, i| {
                slot.* = (try readScalar(arr.child, bytes[i * sz ..][0..sz], base, en)) orelse std.mem.zeroes(arr.child);
            }
            return out;
        },
        else => @compileError("unsupported view field type: " ++ @typeName(T)),
    }
}

/// Read one scalar and convert it to `T`. Returns `null` for the invalid
/// sentinel and for an enum value that is not a named tag.
fn readScalar(comptime T: type, bytes: []const u8, base: BaseType, en: Endian) !?T {
    if (base == .string) return FitError.BaseTypeMismatch;
    const raw = readRaw(bytes, base, en) orelse return null;
    return switch (@typeInfo(T)) {
        .int => switch (raw) {
            .u => |u| std.math.cast(T, u) orelse FitError.ValueOutOfRange,
            .i => |i| std.math.cast(T, i) orelse FitError.ValueOutOfRange,
            .f => FitError.BaseTypeMismatch,
        },
        .float => @floatCast(raw.toF64()),
        .@"enum" => switch (raw) {
            .u => |u| std.enums.fromInt(T, u),
            .i => |i| std.enums.fromInt(T, i),
            .f => FitError.BaseTypeMismatch,
        },
        else => @compileError("unsupported scalar target: " ++ @typeName(T)),
    };
}

// ----------------------------------------------------------------- parser ---

/// A parsed data message, valid only until the next `MessageIterator.next()`.
/// Consume it once, with either `decode` or `fields`; or ignore it and its
/// payload is skipped on the next iteration.
pub const Message = struct {
    parser: *Parser,
    def: *const DefinitionMessage,
    message_number: MesgNum,

    /// Fill a view struct `T` from this message. `m` is the message number the
    /// struct describes; it resolves `T`'s field names against the profile at
    /// comptime. Optional fields absent from the message become `null`; a
    /// required (non-optional) field that is absent or invalid is an error.
    pub fn decode(msg: Message, comptime m: MesgNum, comptime T: type) !T {
        assert(msg.message_number == m);
        msg.assertUnconsumed();

        var out: T = undefined;
        const info = @typeInfo(T).@"struct";
        inline for (info.field_names, info.field_types, info.field_attrs) |field_name, field_type, field_attr| {
            if (comptime field_attr.defaultValue(field_type)) |d| {
                @field(out, field_name) = d;
            } else if (@typeInfo(field_type) == .optional) {
                @field(out, field_name) = null;
            } else if (!msg.def.hasField(comptime profile.field(m, field_name).number)) {
                return FitError.MissingField;
            }
        }

        for (msg.def.fields()) |fdef| {
            const bytes = try msg.parser.takeField(fdef);
            try assignField(m, T, &out, fdef, bytes, msg.def.endian);
        }
        return out;
    }

    /// Walk every field of this message, decoding each against the profile.
    pub fn fields(msg: Message) FieldIterator {
        msg.assertUnconsumed();
        return .{ .parser = msg.parser, .def = msg.def };
    }

    fn assertUnconsumed(msg: Message) void {
        assert(msg.parser.unread == msg.def.payloadSize());
    }
};

pub const MessageIterator = struct {
    parser: *Parser,

    pub fn next(self: MessageIterator) !?Message {
        return self.parser.next();
    }
};

pub const Parser = struct {
    /// Its buffer must hold the largest field of the file (at most 255 bytes),
    /// as each field is taken whole.
    in: *Reader,
    /// Parsed by the first `next()`.
    header: ?FileHeader = null,
    definitions: [max_definitions]?DefinitionMessage = @splat(null),
    /// Bytes of the data section accounted for, including the whole payload of
    /// the current message.
    data_read: u32 = 0,
    /// Payload bytes of the current message not yet taken from `in`.
    unread: u32 = 0,

    pub fn init(in: *Reader) Parser {
        return .{ .in = in };
    }

    /// Iterate the data messages of the file.
    pub fn messages(self: *Parser) MessageIterator {
        return .{ .parser = self };
    }

    /// Take the payload bytes of one field of the current message. They are
    /// valid until the next read from `in`.
    fn takeField(self: *Parser, fdef: FieldDefinition) ![]const u8 {
        const bytes = try self.in.take(fdef.size);
        self.unread -= fdef.size;
        return bytes;
    }

    fn next(self: *Parser) !?Message {
        const header = self.header orelse header: {
            self.header = try self.parseHeader();
            break :header self.header.?;
        };

        // Skip whatever the caller left of the previous message.
        try self.in.discardAll(self.unread);
        self.unread = 0;

        while (self.data_read < header.data_size) {
            const record: RecordHeader = .decode(try self.in.takeByte());
            self.data_read += 1;
            const h = switch (record) {
                .normal => |h| h,
                .compressed_timestamp => return FitError.CompressedTimestampUnsupported,
            };
            if (h.is_definition) {
                try self.parseDefinitionMessage(h);
                continue;
            }
            const def = if (self.definitions[h.local_message_type]) |*def| def else return FitError.UndefinedLocalMessage;
            self.unread = def.payloadSize();
            self.data_read += self.unread;
            return .{ .parser = self, .def = def, .message_number = def.message_number };
        }
        return null;
    }

    fn parseHeader(self: *Parser) !FileHeader {
        const size = try self.in.takeByte();
        if (size < 12) return FitError.InvalidHeader;
        const protocol_version = try self.in.takeByte();
        const profile_version = try self.in.takeInt(u16, .little);
        const data_size = try self.in.takeInt(u32, .little);
        const data_type = try self.in.takeArray(4);
        if (!std.mem.eql(u8, data_type, ".FIT")) return FitError.InvalidMagic;
        const crc = if (size >= 14) try self.in.takeInt(u16, .little) else 0;
        if (size > 14) try self.in.discardAll(size - 14); // unknown extension

        return .{
            .size = size,
            .protocol_version = protocol_version,
            .profile_version = profile_version,
            .data_size = data_size,
            .data_type = data_type.*,
            .crc = crc,
        };
    }

    fn parseDefinitionMessage(self: *Parser, header: RecordHeader.Normal) !void {
        try self.in.discardAll(1); // reserved
        const en = try endian(try self.in.takeByte());
        var def: DefinitionMessage = .{
            .endian = en,
            .message_number = @fromBackingInt(try self.in.takeInt(u16, en)),
            .num_fields = try self.in.takeByte(),
            .field_buffer = undefined,
            .developer_data_size = 0,
        };
        self.data_read += 5;

        for (def.field_buffer[0..def.num_fields]) |*f| {
            f.* = .{
                .field_definition_number = try self.in.takeByte(),
                .size = try self.in.takeByte(),
                .base_type = std.enums.fromInt(BaseType, try self.in.takeByte()) orelse
                    return FitError.InvalidBaseType,
            };
        }
        self.data_read += 3 * @as(u32, def.num_fields);

        if (header.has_developer_data) {
            const num_developer_fields = try self.in.takeByte();
            for (0..num_developer_fields) |_| {
                try self.in.discardAll(1); // field number
                def.developer_data_size += try self.in.takeByte();
                try self.in.discardAll(1); // developer data index
            }
            self.data_read += 1 + 3 * @as(u32, num_developer_fields);
        }

        self.definitions[header.local_message_type] = def;
    }
};

/// Convert a lat/lon coordinate from semicircles to degrees: 2^31 semicircles
/// make 180 degrees.
pub fn degrees(semicircles: i32) f64 {
    const semicircles_per_180_degrees: f64 = std.math.maxInt(i32) + 1;
    return @as(f64, @floatFromInt(semicircles)) * (180.0 / semicircles_per_180_degrees);
}

test "degrees from semicircles" {
    try testing.expectEqual(0.0, degrees(0));
    try testing.expectEqual(90.0, degrees(1 << 30));
    try testing.expectEqual(-90.0, degrees(-(1 << 30)));
    try testing.expectEqual(-180.0, degrees(std.math.minInt(i32)));
}

// ------------------------------------------------------------------ tests ---

// https://github.com/garmin/fit-java-sdk/blob/main/src/test/java/com/garmin/fit/TestData.java
const fit_file_short = [_]u8{
    0x0E, 0x20, 0x8B, 0x08, 0x24, 0x00, 0x00, 0x00, 0x2E, 0x46, 0x49, 0x54, 0x8E, 0xA3, // Header
    0x40, 0x00, 0x00, 0x00, 0x00, 0x04, 0x00, 0x01, 0x00, 0x01, 0x02, 0x84, 0x04, 0x04, 0x86, 0x08, 0x0A, 0x07, // Message Definition
    0x00, 0x04, 0x01, 0x00, 0x00, 0xCA, 0x9A, 0x3B, 0x61, 0x62, 0x63, 0x64, 0x65, 0x66, 0x67, 0x68, 0x69, 0x00, // Message
    0x5D, 0xF2, // CRC
};

test "parse header" {
    var r: Reader = .fixed(&fit_file_short);
    var parser: Parser = .init(&r);

    try testing.expectEqualDeep(FileHeader{
        .size = 14,
        .protocol_version = 32,
        .profile_version = 2187,
        .data_size = 36,
        .data_type = .{ '.', 'F', 'I', 'T' },
        .crc = 41870,
    }, try parser.parseHeader());
}

test "iterate short file" {
    var r: Reader = .fixed(&fit_file_short);
    var parser: Parser = .init(&r);

    var it = parser.messages();
    var count: usize = 0;
    while (try it.next()) |_| count += 1;

    try testing.expectEqual(1, count);
}

/// Comptime helper: a fixed-size, zero-padded byte array holding a string.
fn str(comptime n: usize, comptime s: []const u8) [n]u8 {
    var out: [n]u8 = @splat(0);
    @memcpy(out[0..s.len], s);
    return out;
}

/// The example FIT file from Figure 14 of
/// https://developer.garmin.com/fit/protocol/
///
/// It exercises a full file: a file_id message, developer data definitions
/// (developer_data_id and field_description), and record messages that carry a
/// developer field ("doughnuts_earned"). Architecture is little-endian
/// throughout and every definition uses local message type 0.
const fit_file_figure_14 =
    // File Header (14 bytes). data_size = 222 (0xDE); CRC values are ignored by
    // the parser so they are left as zero.
    [_]u8{ 0x0E, 0x20, 0x8B, 0x08, 0xDE, 0x00, 0x00, 0x00, 0x2E, 0x46, 0x49, 0x54, 0x00, 0x00 } ++

    // Record 1 - Definition: file_id (global msg 0), 5 fields
    //   header, reserved, arch, global msg no (u16), num fields
    [_]u8{ 0x40, 0x00, 0x00, 0x00, 0x00, 0x05 } ++
    [_]u8{ 0x00, 0x01, 0x00 } ++ // type:         #0, 1 byte,  enum
    [_]u8{ 0x01, 0x02, 0x84 } ++ // manufacturer: #1, 2 bytes, uint16
    [_]u8{ 0x02, 0x02, 0x84 } ++ // product:      #2, 2 bytes, uint16
    [_]u8{ 0x03, 0x04, 0x8C } ++ // serial_number:#3, 4 bytes, uint32z
    [_]u8{ 0x04, 0x04, 0x86 } ++ // time_created: #4, 4 bytes, uint32

    // Record 2 - Data: file_id
    [_]u8{0x00} ++ // header
    [_]u8{0x04} ++ // type = 4
    [_]u8{ 0x0F, 0x00 } ++ // manufacturer = 15
    [_]u8{ 0x16, 0x00 } ++ // product = 22
    [_]u8{ 0xD2, 0x04, 0x00, 0x00 } ++ // serial_number = 1234
    [_]u8{ 0x28, 0xC6, 0x0A, 0x25 } ++ // time_created = 621463080

    // Record 3 - Definition: developer_data_id (global msg 207), 2 fields
    [_]u8{ 0x40, 0x00, 0x00, 0xCF, 0x00, 0x02 } ++
    [_]u8{ 0x01, 0x10, 0x0D } ++ // application_id:        #1, 16 bytes, byte
    [_]u8{ 0x03, 0x01, 0x02 } ++ // developer_data_index: #3,  1 byte,  uint8

    // Record 4 - Data: developer_data_id
    [_]u8{0x00} ++ // header
    [_]u8{ 0x2C, 0x01, 0x02, 0x02, 0x03, 0x01, 0x0F, 0x01, 0x02, 0x0C, 0x1F, 0x29, 0x01, 0x02, 0x01, 0x58 } ++ // application_id (16 bytes)
    [_]u8{0x00} ++ // developer_data_index = 0

    // Record 5 - Definition: field_description (global msg 206), 5 fields
    [_]u8{ 0x40, 0x00, 0x00, 0xCE, 0x00, 0x05 } ++
    [_]u8{ 0x00, 0x01, 0x02 } ++ // developer_data_index:    #0,  1 byte,  uint8
    [_]u8{ 0x01, 0x01, 0x02 } ++ // field_definition_number: #1,  1 byte,  uint8
    [_]u8{ 0x02, 0x01, 0x02 } ++ // fit_base_type_id:        #2,  1 byte,  uint8
    [_]u8{ 0x03, 0x40, 0x07 } ++ // field_name:              #3, 64 bytes, string
    [_]u8{ 0x08, 0x10, 0x07 } ++ // units:                   #8, 16 bytes, string

    // Record 6 - Data: field_description
    [_]u8{0x00} ++ // header
    [_]u8{0x00} ++ // developer_data_index = 0
    [_]u8{0x00} ++ // field_definition_number = 0
    [_]u8{0x01} ++ // fit_base_type_id = 1 (sint8)
    str(64, "doughnuts_earned") ++ // field_name
    str(16, "doughnuts") ++ // units

    // Record 7 - Definition (with developer data): record (global msg 20), 4 fields
    [_]u8{ 0x60, 0x00, 0x00, 0x14, 0x00, 0x04 } ++
    [_]u8{ 0x03, 0x01, 0x02 } ++ // heart_rate: #3, 1 byte,  uint8
    [_]u8{ 0x04, 0x01, 0x02 } ++ // cadence:    #4, 1 byte,  uint8
    [_]u8{ 0x05, 0x04, 0x86 } ++ // distance:   #5, 4 bytes, uint32
    [_]u8{ 0x06, 0x02, 0x84 } ++ // speed:      #6, 2 bytes, uint16
    [_]u8{0x01} ++ // num_dev_fields = 1
    [_]u8{ 0x00, 0x01, 0x00 } ++ // dev field: field_num 0, 1 byte, developer_data_index 0

    // Record 8 - Data: record
    [_]u8{0x00} ++ // header
    [_]u8{0x8C} ++ // heart_rate = 140
    [_]u8{0x58} ++ // cadence = 88
    [_]u8{ 0xFE, 0x01, 0x00, 0x00 } ++ // distance = 510
    [_]u8{ 0xF0, 0x0A } ++ // speed = 2800
    [_]u8{0x01} ++ // doughnuts_earned = 1

    // Record 9 - Data: record
    [_]u8{0x00} ++
    [_]u8{0x8F} ++ // heart_rate = 143
    [_]u8{0x5A} ++ // cadence = 90
    [_]u8{ 0x20, 0x08, 0x00, 0x00 } ++ // distance = 2080
    [_]u8{ 0x68, 0x0B } ++ // speed = 2920
    [_]u8{0x01} ++ // doughnuts_earned = 1

    // Record 10 - Data: record
    [_]u8{0x00} ++
    [_]u8{0x90} ++ // heart_rate = 144
    [_]u8{0x5C} ++ // cadence = 92
    [_]u8{ 0x7E, 0x0E, 0x00, 0x00 } ++ // distance = 3710
    [_]u8{ 0xEA, 0x0B } ++ // speed = 3050
    [_]u8{0x01} ++ // doughnuts_earned = 1

    // CRC (2 bytes, ignored by the parser)
    [_]u8{ 0x00, 0x00 };

const FileId = struct {
    type: Types.File,
    manufacturer: u16,
    product: u16,
    serial_number: ?u32,
    time_created: u32,
};

const Record = struct {
    heart_rate: u8,
    cadence: u8,
    distance: f32,
    speed: ?f16,
    // Not present on the wire in the figure-14 fixture below, so this always
    // decodes to `null`. It's included so `decode(.record, Record)` still
    // instantiates `assignField`'s scale/offset compile-time check against
    // `altitude` (scale = 5, offset = 500): this field is a regression guard
    // that `Record.altitude` stays a float. Changing it back to an integer
    // (e.g. `?u16`) must fail to compile — see `profile.needsFloatTarget`.
    altitude: ?f16,
};

test "decode figure 14" {
    var r: Reader = .fixed(&fit_file_figure_14);
    var parser: Parser = .init(&r);
    var it = parser.messages();

    var file_ids: usize = 0;
    var records: usize = 0;

    while (try it.next()) |msg| {
        switch (msg.message_number) {
            .file_id => {
                const f = try msg.decode(.file_id, FileId);
                file_ids += 1;
                try testing.expectEqual(Types.File.activity, f.type);
                try testing.expectEqual(15, f.manufacturer);
                try testing.expectEqual(22, f.product);
                try testing.expectEqual(1234, f.serial_number);
                try testing.expectEqual(621463080, f.time_created);
            },
            .record => {
                const rec = try msg.decode(.record, Record);
                records += 1;
                switch (records) {
                    1 => {
                        try testing.expectEqual(140, rec.heart_rate);
                        try testing.expectEqual(88, rec.cadence);
                        try testing.expectEqual(5.1, rec.distance);
                        try testing.expectEqual(2.8, rec.speed);
                    },
                    2 => {
                        try testing.expectEqual(143, rec.heart_rate);
                        try testing.expectEqual(2.92, rec.speed);
                    },
                    3 => {
                        try testing.expectEqual(144, rec.heart_rate);
                        try testing.expectEqual(3.05, rec.speed);
                    },
                    else => {},
                }
            },
            else => {}, // developer_data_id / field_description: auto-skipped
        }
    }

    try testing.expectEqual(1, file_ids);
    try testing.expectEqual(3, records);
}

test "fields() dynamic decode of figure 14" {
    var r: Reader = .fixed(&fit_file_figure_14);
    var parser: Parser = .init(&r);
    var it = parser.messages();

    // Record 2 — file_id: enum tag name, and plain scalars.
    {
        const msg = (try it.next()).?;
        try testing.expectEqual(MesgNum.file_id, msg.message_number);
        var f = msg.fields();

        const type_field = (try f.next()).?;
        try testing.expectEqual(0, type_field.number);
        try testing.expectEqualStrings("type", type_field.name.?);
        try testing.expectEqual(4, type_field.value.enum_tag.value);
        try testing.expectEqualStrings("activity", type_field.value.enum_tag.name.?);

        try testing.expectEqual(15, (try f.next()).?.value.uint); // manufacturer
        try testing.expectEqual(22, (try f.next()).?.value.uint); // product
        try testing.expectEqual(1234, (try f.next()).?.value.uint); // serial_number
        try testing.expectEqual(621463080, (try f.next()).?.value.uint); // time_created
        try testing.expectEqual(null, try f.next()); // exhausted
    }

    // Record 4 — developer_data_id: a byte array.
    {
        const msg = (try it.next()).?;
        try testing.expectEqual(MesgNum.developer_data_id, msg.message_number);
        var f = msg.fields();

        const app_id = (try f.next()).?;
        try testing.expectEqual(1, app_id.number);
        try testing.expectEqualStrings("application_id", app_id.name.?);
        try testing.expectEqual(16, app_id.value.array.len());

        try testing.expectEqual(0, (try f.next()).?.value.uint); // developer_data_index
        try testing.expectEqual(null, try f.next());
    }

    // Record 6 — field_description: string fields.
    {
        const msg = (try it.next()).?;
        try testing.expectEqual(MesgNum.field_description, msg.message_number);
        var f = msg.fields();

        _ = (try f.next()).?; // developer_data_index
        _ = (try f.next()).?; // field_definition_number
        _ = (try f.next()).?; // fit_base_type_id
        const field_name = (try f.next()).?;
        try testing.expectEqualStrings("doughnuts_earned", field_name.value.string);
        const units = (try f.next()).?;
        try testing.expectEqualStrings("doughnuts", units.value.string);
        try testing.expectEqual(null, try f.next());
    }

    // Record 8 — record: scaled floats with units, and a skipped developer field.
    {
        const msg = (try it.next()).?;
        try testing.expectEqual(MesgNum.record, msg.message_number);
        var f = msg.fields();

        const hr = (try f.next()).?;
        try testing.expectEqualStrings("heart_rate", hr.name.?);
        try testing.expectEqual(140, hr.value.uint);
        try testing.expectEqualStrings("bpm", hr.units.?);

        try testing.expectEqual(88, (try f.next()).?.value.uint); // cadence

        const distance = (try f.next()).?;
        try testing.expectEqualStrings("distance", distance.name.?);
        try testing.expectEqual(5.1, distance.value.float); // 510 / scale 100
        try testing.expectEqualStrings("m", distance.units.?);

        const speed = (try f.next()).?;
        try testing.expectEqual(2.8, speed.value.float); // 2800 / scale 1000
        try testing.expectEqual(null, try f.next()); // developer field skipped
    }
}

test "fields() abandoned mid-walk stays aligned" {
    var r: Reader = .fixed(&fit_file_figure_14);
    var parser: Parser = .init(&r);
    var it = parser.messages();

    var count: usize = 0;
    while (try it.next()) |msg| {
        // Read just one field, then abandon — the parser must still skip the
        // rest of the payload on the next `next()`.
        var f = msg.fields();
        _ = try f.next();
        count += 1;
    }

    try testing.expectEqual(6, count);
}

test "readField string and numeric array" {
    const s = try readField([4]u8, .{ .field_definition_number = 0, .size = 4, .base_type = .string }, &.{ 'h', 'i', 0, 0 }, .little);
    try testing.expectEqualStrings("hi", std.mem.sliceTo(&s.?, 0));

    const arr = try readField([2]u16, .{ .field_definition_number = 1, .size = 4, .base_type = .uint16 }, &.{ 0x0A, 0x00, 0x14, 0x00 }, .little);
    try testing.expectEqual([2]u16{ 10, 20 }, arr.?);
}

test "arity mismatch: scalar target for an array field" {
    // wire holds 2 x uint16 but the target is a scalar
    try testing.expectError(FitError.ArityMismatch, readField(u16, .{ .field_definition_number = 0, .size = 4, .base_type = .uint16 }, &.{ 0x01, 0x00, 0x02, 0x00 }, .little));
}

test "value out of range for target" {
    try testing.expectError(FitError.ValueOutOfRange, readField(u8, .{ .field_definition_number = 0, .size = 2, .base_type = .uint16 }, &.{ 0x00, 0x01 }, .little));
}

test "data message without a definition" {
    var r: Reader = .fixed(fit_file_short[0..14] ++ [_]u8{0x00});
    var parser: Parser = .init(&r);
    try testing.expectError(FitError.UndefinedLocalMessage, parser.messages().next());
}

test "iterate figure 14 without decoding" {
    // Every message auto-skips; the whole file drains cleanly.
    var r: Reader = .fixed(&fit_file_figure_14);
    var parser: Parser = .init(&r);
    var it = parser.messages();

    var count: usize = 0;
    while (try it.next()) |_| count += 1;

    // file_id, developer_data_id, field_description, 3x record
    try testing.expectEqual(6, count);
}

test {
    _ = profile;
}
