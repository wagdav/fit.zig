//! By convention, root.zig is the root source file when making a package.
const std = @import("std");
const assert = std.debug.assert;
const Endian = std.builtin.Endian;
const Io = std.Io;
const Reader = std.Io.Reader;
const testing = std.testing;

const profile = @import("profile.zig");
pub const MesgNum = profile.MesgNum;
pub const Types = @import("types.zig");

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
fn StripOptional(comptime T: type) type {
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

/// Reinterpret a raw wire scalar as an unsigned integer (for enum tags).
fn rawToU64(raw: Raw) u64 {
    return switch (raw) {
        .u => |u| u,
        .i => |i| @bitCast(i),
        .f => unreachable,
    };
}

/// Widen a raw wire scalar to `f64` (for scaled/offset and array values).
fn rawToF64(raw: Raw) f64 {
    return switch (raw) {
        .u => |u| @floatFromInt(u),
        .i => |i| @floatFromInt(i),
        .f => |f| f,
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

/// Read one raw scalar per its wire base type. Returns `null` on the invalid
/// sentinel. A free function so both the `Parser` and the dynamic `Array`
/// decoder (which reads from a fixed reader over a byte slice) can use it.
fn readRaw(in: *Reader, base: BaseType, en: Endian) !?Raw {
    const invalid = base.invalid();
    switch (base) {
        .enum_, .uint8, .uint8z, .byte => {
            const v = try in.takeByte();
            return if (v == invalid) null else .{ .u = v };
        },
        .sint8 => {
            const v = try in.takeInt(i8, en);
            return if (@as(u8, @bitCast(v)) == invalid) null else .{ .i = v };
        },
        .uint16, .uint16z => {
            const v = try in.takeInt(u16, en);
            return if (v == invalid) null else .{ .u = v };
        },
        .sint16 => {
            const v = try in.takeInt(i16, en);
            return if (@as(u16, @bitCast(v)) == invalid) null else .{ .i = v };
        },
        .uint32, .uint32z => {
            const v = try in.takeInt(u32, en);
            return if (v == invalid) null else .{ .u = v };
        },
        .sint32 => {
            const v = try in.takeInt(i32, en);
            return if (@as(u32, @bitCast(v)) == invalid) null else .{ .i = v };
        },
        .float32 => {
            const b = try in.takeInt(u32, en);
            return if (b == invalid) null else .{ .f = @as(f32, @bitCast(b)) };
        },
        .uint64, .uint64z => {
            const v = try in.takeInt(u64, en);
            return if (v == invalid) null else .{ .u = v };
        },
        .sint64 => {
            const v = try in.takeInt(i64, en);
            return if (@as(u64, @bitCast(v)) == invalid) null else .{ .i = v };
        },
        .float64 => {
            const b = try in.takeInt(u64, en);
            return if (b == invalid) null else .{ .f = @as(f64, @bitCast(b)) };
        },
        .string => return FitError.BaseTypeMismatch,
    }
}

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
        const sz = self.base.size();
        assert(i < self.len());
        var r: Reader = .fixed(self.bytes[i * sz .. (i + 1) * sz]);
        const raw = (readRaw(&r, self.base, self.endian) catch unreachable) orelse
            return std.math.nan(f64);
        return applyScaleOffset(rawToF64(raw), self.scale, self.offset);
    }
};

/// Walk every (non-developer) field of a message in wire order, decoding each
/// against the profile — the dynamic counterpart to the typed `decode(m, T)`,
/// à la `fitdump`. Consumes the message just like `decode`: use one or the
/// other, once. Developer fields are not decoded (their base type lives in a
/// `field_description` message the parser does not track) but their bytes are
/// skipped so the stream stays aligned.
pub const FieldIterator = struct {
    parser: *Parser,
    def: *const DefinitionMessage,
    message_number: MesgNum,
    endian: Endian,
    /// Index of the next regular field to yield.
    index: u8,
    done: bool,

    pub fn next(self: *FieldIterator) !?Field {
        if (self.done) return null;

        if (self.index < self.def.num_fields) {
            const fdef = self.def.fields[self.index];
            self.index += 1;
            const info = profile.lookup(self.message_number, fdef.field_definition_number);
            const value = try self.readValue(fdef, info);
            self.parser.advancePayload(fdef.size);
            return .{
                .number = fdef.field_definition_number,
                .name = if (info) |i| i.name else null,
                .units = if (info) |i| i.units else null,
                .value = value,
            };
        }

        // All regular fields yielded: skip developer-field bytes and finalize
        // so the message is fully consumed for the next `MessageIterator.next()`.
        self.parser.advancePayload(try self.parser.skipDeveloperFields(self.def));
        self.parser.pending = null;
        self.done = true;
        return null;
    }

    fn readValue(self: *FieldIterator, fdef: FieldDefinition, info: ?profile.FieldInfo) !Value {
        const base = fdef.base_type;
        const in = self.parser.in;

        if (base == .string) {
            const bytes = try in.take(fdef.size);
            return .{ .string = std.mem.sliceTo(bytes, 0) };
        }

        // Anything wider than one element is a multi-value field.
        if (fdef.size != base.size()) {
            const bytes = try in.take(fdef.size);
            return .{ .array = .{
                .bytes = bytes,
                .base = base,
                .endian = self.endian,
                .scale = if (info) |i| i.scale else null,
                .offset = if (info) |i| i.offset else null,
            } };
        }

        const raw = (try readRaw(in, base, self.endian)) orelse return .invalid;
        if (info) |i| {
            if (i.enumName) |namer| {
                const v = rawToU64(raw);
                return .{ .enum_tag = .{ .value = v, .name = namer(v) } };
            }
            if (i.scale != null or i.offset != null) {
                return .{ .float = applyScaleOffset(rawToF64(raw), i.scale, i.offset) };
            }
        }
        return switch (raw) {
            .u => |u| .{ .uint = u },
            .i => |x| .{ .int = x },
            .f => |x| .{ .float = x },
        };
    }
};

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
        const parser = msg.parser;
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
            const assigned = try parser.assignField(m, T, &out, fdef, en);
            if (!assigned) try parser.in.discardAll(fdef.size); // no field wanted it
        }

        // Developer fields are not decoded by the typed path; skip their bytes
        // so the stream stays aligned for the next record.
        _ = try parser.skipDeveloperFields(def);

        parser.consumePending();
        return out;
    }

    /// Walk every field of this message, decoding each against the profile.
    /// The dynamic counterpart to `decode`; see `FieldIterator`. Like `decode`
    /// it consumes the message, so call one or the other, once.
    pub fn fields(msg: Message) !FieldIterator {
        return .{
            .parser = msg.parser,
            .def = msg.def,
            .message_number = msg.message_number,
            .endian = try endian(msg.def.arch),
            .index = 0,
            .done = false,
        };
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

    /// Account for `n` payload bytes just read field-by-field by a
    /// `FieldIterator`, keeping `pending` (bytes still owed) and `data_read` in
    /// sync so an abandoned field walk still leaves the stream aligned for the
    /// next `MessageIterator.next()`.
    fn advancePayload(self: *Parser, n: u32) void {
        self.data_read += n;
        self.pending = self.pending.? - n;
    }

    /// Discard the developer-field bytes of `def` — neither decode path decodes
    /// them (their base type lives in an untracked `field_description` message).
    /// Returns the number of bytes skipped so the caller can update accounting.
    fn skipDeveloperFields(self: *Parser, def: *const DefinitionMessage) !u32 {
        var n: u32 = 0;
        for (def.developer_fields[0..def.num_developer_fields]) |dfd| n += dfd.size;
        try self.in.discardAll(n);
        return n;
    }

    fn next(self: *Parser) !?Message {
        if (!self.started) {
            self.header = try self.parseHeader();
            self.data_read = 0;
            self.started = true;
        }

        // A message yielded but never decoded still owns its payload bytes.
        if (self.pending) |remaining| {
            try self.in.discardAll(remaining);
            self.consumePending();
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

    fn parseHeader(self: *Parser) !FileHeader {
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
    fn assignField(
        self: *Parser,
        comptime m: MesgNum,
        comptime T: type,
        out: *T,
        fdef: FieldDefinition,
        en: Endian,
    ) !bool {
        inline for (@typeInfo(T).@"struct".fields) |view_field| {
            const field = comptime profile.field(m, view_field.name);
            if (fdef.field_definition_number == field.number) {
                // The underlying type of the view struct's field
                const ftype = StripOptional(view_field.type);

                if (try self.readField(ftype, fdef, en)) |raw| {
                    // Scale/Offset: When specified, the binary quantity is divided by the scale factor and then the offset is
                    // subtracted, yielding a floating point quantity.
                    if (comptime profile.needsFloatTarget(field) and @typeInfo(ftype) != .float)
                        @compileError(@typeName(T) ++ "." ++ view_field.name ++ " should be float because the field uses scale/offset.");

                    var value = raw;
                    if (field.scale) |scale| value /= scale;
                    if (field.offset) |offset| value -= offset;

                    // assign the field's value
                    @field(out, view_field.name) = value;
                } else if (comptime isRequired(view_field)) {
                    return FitError.MissingField; // required, present but invalid
                } else {
                    // optional stays null, or defaulted keeps its default
                }
                return true;
            }
        }
        return false;
    }

    /// Read one view-struct field. Returns `null` when the field carries the FIT "invalid" sentinel.
    fn readField(self: *Parser, comptime Child: type, fdef: FieldDefinition, en: Endian) !?Child {
        const base = fdef.base_type;
        switch (@typeInfo(Child)) {
            .int, .float, .@"enum" => {
                if (base == .string) return FitError.BaseTypeMismatch;
                if (fdef.size != base.size()) return FitError.ArityMismatch;
                return self.readScalar(Child, base, en);
            },
            .array => |arr| {
                if (arr.child == u8 and (base == .string or base == .byte)) {
                    return try self.readString(Child, fdef);
                }
                if (fdef.size != base.size() * arr.len) return FitError.ArityMismatch;
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
        const raw = (try readRaw(self.in, base, en)) orelse return null;
        return convert(Child, raw);
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

/// Convert a lat/lon coordinate from semicircles to degrees
pub fn degrees(semicircles: i32) f64 {
    return @as(f64, @floatFromInt(semicircles)) * (180.0 / 2147483648.0);
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
        var f = try msg.fields();

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

    // Record 4 — developer_data_id: unknown message → name null; a byte array.
    {
        const msg = (try it.next()).?;
        try testing.expectEqual(MesgNum.developer_data_id, msg.message_number);
        var f = try msg.fields();

        const app_id = (try f.next()).?;
        try testing.expectEqual(1, app_id.number);
        try testing.expectEqual(null, app_id.name); // no profile table
        try testing.expectEqual(16, app_id.value.array.len());

        try testing.expectEqual(0, (try f.next()).?.value.uint); // developer_data_index
        try testing.expectEqual(null, try f.next());
    }

    // Record 6 — field_description: unknown message with string fields.
    {
        const msg = (try it.next()).?;
        try testing.expectEqual(MesgNum.field_description, msg.message_number);
        var f = try msg.fields();

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
        var f = try msg.fields();

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
        var f = try msg.fields();
        _ = try f.next();
        count += 1;
    }

    try testing.expectEqual(6, count);
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
