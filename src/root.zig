//! By convention, root.zig is the root source file when making a package.
const std = @import("std");
const assert = std.debug.assert;
const Endian = std.builtin.Endian;
const Io = std.Io;
const Reader = std.Io.Reader;
const testing = std.testing;

const profile = @import("profile.zig");
const MesgNum = profile.MesgNum;
const types = @import("types.zig");
pub const File = types.File;
pub const Sport = types.Sport;

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
        local_message_type: u4, // bits 0..3
        reserved: u1, // bit 4
        has_developer_data: bool, // bit 5
        is_definition: bool, // bit 6
        header_type: Type, // bit 7
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
        if (raw & 0b1000_0000 == 0) {
            const h: Normal = @bitCast(raw);
            assert(h.header_type == .normal);
            return .{ .normal = h };
        } else {
            const h: CompressedTimestamp = @bitCast(raw);
            assert(h.header_type == .compressed_timestamp);
            return .{ .compressed_timestamp = h };
        }
    }
};

pub const FitError = error{
    InvalidArchitecture,
    InvalidBaseType,
    InvalidMagic,
    CompressedTimestampUnsupported,
    /// A view-struct field's wire arity did not match its target type.
    ArityMismatch,
    /// A field's wire base type is incompatible with its target type.
    BaseTypeMismatch,
    /// A required (non-optional) view-struct field was absent or invalid.
    MissingField,
};

const max_fields = 256;
const max_developer_fields = 256;

/// See Table 4 of https://developer.garmin.com/fit/protocol/
const DefinitionMessage = struct {
    arch: u8,
    global_message_number: u16,
    num_fields: u8,
    fields: [max_fields]FieldDefinition,
    num_developer_fields: u8,
    developer_fields: [max_developer_fields]DeveloperFieldDefinition,
};

/// See Table 5 of https://developer.garmin.com/fit/protocol/
const FieldDefinition = struct {
    field_definition_number: u8,
    size: u8,
    base_type: BaseType,
};

/// See Table 8 of https://developer.garmin.com/fit/protocol/
const DeveloperFieldDefinition = struct {
    field_definition_number: u8,
    size: u8,
    developer_data_index: u8,
};

fn endian(arch: u8) !Endian {
    return switch (arch) {
        0 => .little,
        1 => .big,
        else => FitError.InvalidArchitecture,
    };
}

/// See Table 6 of https://developer.garmin.com/fit/protocol/
const BaseType = enum(u8) {
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

    fn decode(raw: u8) !BaseType {
        return std.enums.fromInt(BaseType, raw) orelse FitError.InvalidBaseType;
    }

    /// Bytes per element.
    fn size(self: BaseType) u8 {
        return switch (self) {
            .enum_, .sint8, .uint8, .string, .uint8z, .byte => 1,
            .sint16, .uint16, .uint16z => 2,
            .sint32, .uint32, .float32, .uint32z => 4,
            .float64, .sint64, .uint64, .uint64z => 8,
        };
    }

    /// The value that indicates the field is not set.
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

const max_definitions = 16;

/// Total number of payload bytes a data message of this definition occupies.
fn payloadSize(def: *const DefinitionMessage) u32 {
    var n: u32 = 0;
    for (def.fields[0..def.num_fields]) |f| n += f.size;
    for (def.developer_fields[0..def.num_developer_fields]) |f| n += f.size;
    return n;
}

/// Whether the definition declares a field with the given definition number.
fn hasField(def: *const DefinitionMessage, number: u8) bool {
    for (def.fields[0..def.num_fields]) |f| {
        if (f.field_definition_number == number) return true;
    }
    return false;
}

/// `T` with any outer optional stripped (`?u32 -> u32`, `u32 -> u32`).
fn Strip(comptime T: type) type {
    return switch (@typeInfo(T)) {
        .optional => |o| o.child,
        else => T,
    };
}

/// A view-struct field is required when it is non-optional and has no default:
/// it must be filled from the wire, or `decode` fails. Optional or defaulted
/// fields are always satisfied.
fn isRequired(comptime f: std.builtin.Type.StructField) bool {
    return f.defaultValue() == null and @typeInfo(f.type) != .optional;
}

/// A raw wire scalar, decoded to a size-independent representation so the
/// target-type conversion can be a single instantiation per target.
const Raw = union(enum) {
    u: u64,
    i: i64,
    f: f64,
};

/// Convert a raw wire scalar to the view-struct target type. Returns `null`
/// when the value cannot be represented (e.g. an out-of-range enum tag).
fn convert(comptime Child: type, raw: Raw) ?Child {
    return switch (@typeInfo(Child)) {
        .int => switch (raw) {
            .u => |u| @intCast(u),
            .i => |i| @intCast(i),
            .f => unreachable, // float wire value into an integer target
        },
        .float => switch (raw) {
            .u => |u| @floatFromInt(u),
            .i => |i| @floatFromInt(i),
            .f => |f| @floatCast(f),
        },
        .@"enum" => switch (raw) {
            .u => |u| std.enums.fromInt(Child, u),
            .i => |i| std.enums.fromInt(Child, i),
            .f => unreachable,
        },
        else => @compileError("unsupported scalar target: " ++ @typeName(Child)),
    };
}

/// A parsed data message, valid only until the next `MessageIterator.next()`.
/// Decode it into a view struct with `decode`, or ignore it and its payload is
/// skipped automatically on the next iteration.
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
        const self = msg.parser;
        const def = msg.def;
        const en = try endian(def.arch);
        const sfields = @typeInfo(T).@"struct".fields;

        // Seed optional and defaulted fields, and check that every required
        // field is actually present in this message — leaving the read loop to
        // just assign values.
        var out: T = undefined;
        inline for (sfields) |f| {
            if (comptime f.defaultValue()) |d| {
                @field(out, f.name) = d;
            } else if (@typeInfo(f.type) == .optional) {
                @field(out, f.name) = null;
            } else if (!hasField(def, comptime profile.field(m, f.name).number)) {
                return FitError.MissingField; // required but absent
            }
        }

        // Read the wire in order, assigning matched fields and discarding the rest.
        for (def.fields[0..def.num_fields]) |fdef| {
            const assigned = try self.assignField(m, T, &out, fdef, en);
            if (!assigned) try self.in.discardAll(fdef.size); // no field wanted it
        }

        // Developer fields are not decoded by the typed path; skip their bytes
        // so the stream stays aligned for the next record.
        for (def.developer_fields[0..def.num_developer_fields]) |dfd| {
            try self.in.discardAll(dfd.size);
        }

        self.consumePending();
        return out;
    }
};

pub const MessageIterator = struct {
    parser: *Parser,

    pub fn next(self: MessageIterator) !?Message {
        return self.parser.next();
    }
};

pub const Parser = struct {
    in: *Reader,
    header: FileHeader,
    definitions: [max_definitions]DefinitionMessage,
    data_read: u32,
    started: bool,
    /// Bytes of the last-yielded data message not yet consumed (via `decode` or
    /// an auto-skip). Valid-until-next-`next()` bookkeeping.
    pending: ?u32,

    pub fn init(in: *Reader) Parser {
        return .{
            .in = in,
            .header = undefined,
            .definitions = undefined,
            .data_read = 0,
            .started = false,
            .pending = null,
        };
    }

    /// Iterate the data messages of the file. Parses the header lazily on the
    /// first `next()`.
    pub fn messages(self: *Parser) MessageIterator {
        return .{ .parser = self };
    }

    fn consumePending(self: *Parser) void {
        if (self.pending) |remaining| {
            self.data_read += remaining;
            self.pending = null;
        }
    }

    fn next(self: *Parser) !?Message {
        if (!self.started) {
            try self.parseHeader();
            self.data_read = 0;
            self.started = true;
        }

        // A message yielded but never decoded still owns its payload bytes.
        if (self.pending) |remaining| {
            try self.in.discardAll(remaining);
            self.data_read += remaining;
            self.pending = null;
        }

        while (self.data_read < self.header.data_size) {
            const rec: RecordHeader = .decode(try self.in.takeByte());
            self.data_read += 1;
            switch (rec) {
                .normal => |h| {
                    if (h.is_definition) {
                        try self.parseDefinitionMessage(h);
                    } else {
                        const def = &self.definitions[h.local_message_type];
                        self.pending = payloadSize(def);
                        return .{
                            .parser = self,
                            .def = def,
                            .message_number = @enumFromInt(def.global_message_number),
                        };
                    }
                },
                .compressed_timestamp => return FitError.CompressedTimestampUnsupported,
            }
        }
        return null;
    }

    fn parseHeader(self: *Parser) !void {
        const size = try self.in.takeByte();
        const protocol_version = try self.in.takeByte();
        const profile_version = try self.in.takeInt(u16, .little);
        const data_size = try self.in.takeInt(u32, .little);
        const data_type = try self.in.takeArray(4);
        if (!std.mem.eql(u8, data_type, ".FIT")) return FitError.InvalidMagic;

        // Decode CRC
        const crc = if (size > 12) try self.in.takeInt(u16, .little) else 0;

        // Ignore the rest of the header
        if (size > 14) {
            _ = try self.in.discardAll(size - 14);
        }

        self.header = .{
            .size = size,
            .protocol_version = protocol_version,
            .profile_version = profile_version,
            .data_size = data_size,
            .data_type = data_type.*,
            .crc = crc,
        };
    }

    fn parseDefinitionMessage(self: *Parser, header: RecordHeader.Normal) !void {
        _ = try self.in.discardAll(1); // skip reserved field
        const arch = try self.in.takeByte();
        const global_message_number = try self.in.takeInt(u16, try endian(arch));
        const num_fields = try self.in.takeByte();
        self.data_read += 5;

        var definition: DefinitionMessage = .{
            .arch = arch,
            .global_message_number = global_message_number,
            .num_fields = num_fields,
            .fields = undefined,
            .num_developer_fields = 0,
            .developer_fields = undefined,
        };

        for (0..definition.num_fields) |i| {
            const field_definition_number = try self.in.takeByte();
            const field_size = try self.in.takeByte();
            const base_type = try self.in.takeByte();
            self.data_read += 3;

            definition.fields[i] = .{
                .field_definition_number = field_definition_number,
                .size = field_size,
                .base_type = try .decode(base_type),
            };
        }

        // Parse Developer Data Fields
        if (header.has_developer_data) {
            definition.num_developer_fields = try self.in.takeByte();
            self.data_read += 1;

            for (0..definition.num_developer_fields) |i| {
                definition.developer_fields[i] = .{
                    .field_definition_number = try self.in.takeByte(),
                    .size = try self.in.takeByte(),
                    .developer_data_index = try self.in.takeByte(),
                };
                self.data_read += 3;
            }
        }

        // Save the message definition
        self.definitions[header.local_message_type] = definition;
    }

    /// Assign wire field `fdef` to the matching field of `out`, reading its
    /// value. Returns whether a struct field matched; if none did, the caller
    /// skips the field's bytes.
    fn assignField(self: *Parser, comptime m: MesgNum, comptime T: type, out: *T, fdef: FieldDefinition, en: Endian) !bool {
        inline for (@typeInfo(T).@"struct".fields) |f| {
            const number = comptime profile.field(m, f.name).number;
            if (fdef.field_definition_number == number) {
                if (try self.readField(Strip(f.type), fdef, en)) |value| {
                    @field(out, f.name) = value;
                } else if (comptime isRequired(f)) {
                    return FitError.MissingField; // required, present but invalid
                } // else: optional stays null, or defaulted keeps its default
                return true;
            }
        }
        return false;
    }

    /// Read one view-struct field. Returns `null` when the field carries the
    /// FIT "invalid" sentinel.
    fn readField(self: *Parser, comptime Child: type, fdef: FieldDefinition, en: Endian) !?Child {
        const base = fdef.base_type;
        switch (@typeInfo(Child)) {
            .int, .float, .@"enum" => {
                if (base == .string) return FitError.BaseTypeMismatch;
                if (@divExact(fdef.size, base.size()) != 1) return FitError.ArityMismatch;
                return self.readScalar(Child, base, en);
            },
            .array => |arr| {
                if (arr.child == u8 and (base == .string or base == .byte)) {
                    return try self.readString(Child, fdef);
                }
                if (@divExact(fdef.size, base.size()) != arr.len) return FitError.ArityMismatch;
                var out: Child = undefined;
                for (&out) |*slot| {
                    slot.* = (try self.readScalar(arr.child, base, en)) orelse std.mem.zeroes(arr.child);
                }
                return out;
            },
            else => @compileError("unsupported view field type: " ++ @typeName(Child)),
        }
    }

    fn readScalar(self: *Parser, comptime Child: type, base: BaseType, en: Endian) !?Child {
        const raw = (try self.readRaw(base, en)) orelse return null;
        return convert(Child, raw);
    }

    /// Read one raw scalar per its wire base type. Returns `null` on the invalid
    /// sentinel.
    fn readRaw(self: *Parser, base: BaseType, en: Endian) !?Raw {
        const invalid = base.invalid();
        switch (base) {
            .enum_, .uint8, .uint8z, .byte => {
                const v = try self.in.takeByte();
                return if (v == invalid) null else .{ .u = v };
            },
            .sint8 => {
                const v = try self.in.takeInt(i8, en);
                return if (@as(u8, @bitCast(v)) == invalid) null else .{ .i = v };
            },
            .uint16, .uint16z => {
                const v = try self.in.takeInt(u16, en);
                return if (v == invalid) null else .{ .u = v };
            },
            .sint16 => {
                const v = try self.in.takeInt(i16, en);
                return if (@as(u16, @bitCast(v)) == invalid) null else .{ .i = v };
            },
            .uint32, .uint32z => {
                const v = try self.in.takeInt(u32, en);
                return if (v == invalid) null else .{ .u = v };
            },
            .sint32 => {
                const v = try self.in.takeInt(i32, en);
                return if (@as(u32, @bitCast(v)) == invalid) null else .{ .i = v };
            },
            .float32 => {
                const b = try self.in.takeInt(u32, en);
                return if (b == invalid) null else .{ .f = @as(f32, @bitCast(b)) };
            },
            .uint64, .uint64z => {
                const v = try self.in.takeInt(u64, en);
                return if (v == invalid) null else .{ .u = v };
            },
            .sint64 => {
                const v = try self.in.takeInt(i64, en);
                return if (@as(u64, @bitCast(v)) == invalid) null else .{ .i = v };
            },
            .float64 => {
                const b = try self.in.takeInt(u64, en);
                return if (b == invalid) null else .{ .f = @as(f64, @bitCast(b)) };
            },
            .string => return FitError.BaseTypeMismatch,
        }
    }

    /// Read a string/byte field into a fixed `[N]u8`, truncated to `N`. The full
    /// wire `size` is consumed regardless.
    fn readString(self: *Parser, comptime Child: type, fdef: FieldDefinition) !Child {
        const bytes = try self.in.take(fdef.size);
        const text = std.mem.sliceTo(bytes, 0);
        var out: Child = @splat(0);
        const n = @min(out.len, text.len);
        @memcpy(out[0..n], text[0..n]);
        return out;
    }
};

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

    try parser.parseHeader();

    try testing.expectEqualDeep(FileHeader{
        .size = 14,
        .protocol_version = 32,
        .profile_version = 2187,
        .data_size = 36,
        .data_type = .{ '.', 'F', 'I', 'T' },
        .crc = 41870,
    }, parser.header);
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
    var out = [_]u8{0} ** n;
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
    type: File,
    manufacturer: u16,
    product: u16,
    serial_number: ?u32,
    time_created: u32,
};

const Record = struct {
    heart_rate: u8,
    cadence: u8,
    distance: u32,
    speed: ?u16,
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
                try testing.expectEqual(File.activity, f.type);
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
                        try testing.expectEqual(510, rec.distance);
                        try testing.expectEqual(2800, rec.speed);
                    },
                    3 => {
                        try testing.expectEqual(144, rec.heart_rate);
                        try testing.expectEqual(3050, rec.speed);
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

test "readField string and numeric array" {
    var r: Reader = .fixed(&[_]u8{
        'h', 'i', 0, 0, // string, size 4
        0x0A, 0x00, 0x14, 0x00, // uint16[2] = { 10, 20 }
    });
    var p: Parser = .init(&r);

    const s = try p.readField([4]u8, .{ .field_definition_number = 0, .size = 4, .base_type = .string }, .little);
    try testing.expectEqualStrings("hi", std.mem.sliceTo(&s.?, 0));

    const arr = try p.readField([2]u16, .{ .field_definition_number = 1, .size = 4, .base_type = .uint16 }, .little);
    try testing.expectEqual([2]u16{ 10, 20 }, arr.?);
}

test "arity mismatch: scalar target for an array field" {
    var r: Reader = .fixed(&[_]u8{ 0x01, 0x00, 0x02, 0x00 });
    var p: Parser = .init(&r);
    // wire holds 2 x uint16 but the target is a scalar
    try testing.expectError(FitError.ArityMismatch, p.readField(u16, .{ .field_definition_number = 0, .size = 4, .base_type = .uint16 }, .little));
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
