//! By convention, root.zig is the root source file when making a package.
const std = @import("std");
const assert = std.debug.assert;
const Endian = std.builtin.Endian;
const Io = std.Io;
const Reader = std.Io.Reader;
const testing = std.testing;

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

    // See Table 2 of https://developer.garmin.com/fit/protocol/
    const Normal = packed struct(u8) {
        local_message_type: u4, // bits 0..3
        reserved: u1, // bit 4
        has_developer_data: bool, // bit 5
        is_definition: bool, // bit 6
        header_type: Type, // bit 7
    };

    // See Table 3 of https://developer.garmin.com/fit/protocol/
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
};

const max_definitions = 16;
const max_fields = 256;
const DefinitionMessage = struct {
    arch: u8,
    global_message_number: u16,
    num_fields: u8,
    fields: [max_fields]FieldDefinition,
};

// See Table 5 of https://developer.garmin.com/fit/protocol/
const FieldDefinition = struct {
    field_definition_number: u8,
    size: u8,
    base_type: BaseType,
};

fn endian(arch: u8) !Endian {
    return switch (arch) {
        0 => .little,
        1 => .big,
        else => FitError.InvalidArchitecture,
    };
}

/// See Table 6 of https://developer.garmin.com/fit/protocol/
const BaseType = struct {
    /// Whether the type's multi-byte values are affected by the definition's
    /// architecture (bit 7 of the base type field byte).
    endian_ability: bool,
    name: []const u8,
    /// The value used to indicate the field is not set.
    invalid: u64,
    /// Bytes per element.
    size: u8,
    number: u8,

    /// Rows indexed by base type number (bits 0..4 of the base type field byte).
    /// See Table 7 of https://developer.garmin.com/fit/protocol/
    const table = [_]struct { name: []const u8, invalid: u64, size: u8 }{
        .{ .name = "enum", .invalid = 0xFF, .size = 1 }, // 0
        .{ .name = "sint8", .invalid = 0x7F, .size = 1 }, // 1
        .{ .name = "uint8", .invalid = 0xFF, .size = 1 }, // 2
        .{ .name = "sint16", .invalid = 0x7FFF, .size = 2 }, // 3
        .{ .name = "uint16", .invalid = 0xFFFF, .size = 2 }, // 4
        .{ .name = "sint32", .invalid = 0x7FFFFFFF, .size = 4 }, // 5
        .{ .name = "uint32", .invalid = 0xFFFFFFFF, .size = 4 }, // 6
        .{ .name = "string", .invalid = 0x00, .size = 1 }, // 7
        .{ .name = "float32", .invalid = 0xFFFFFFFF, .size = 4 }, // 8
        .{ .name = "float64", .invalid = 0xFFFFFFFFFFFFFFFF, .size = 8 }, // 9
        .{ .name = "uint8z", .invalid = 0x00, .size = 1 }, // 10
        .{ .name = "uint16z", .invalid = 0x0000, .size = 2 }, // 11
        .{ .name = "uint32z", .invalid = 0x00000000, .size = 4 }, // 12
        .{ .name = "byte", .invalid = 0xFF, .size = 1 }, // 13
        .{ .name = "sint64", .invalid = 0x7FFFFFFFFFFFFFFF, .size = 8 }, // 14
        .{ .name = "uint64", .invalid = 0xFFFFFFFFFFFFFFFF, .size = 8 }, // 15
        .{ .name = "uint64z", .invalid = 0x0000000000000000, .size = 8 }, // 16
    };

    fn decode(raw: u8) !BaseType {
        const number = raw & 0x1F; // bits 0..4
        if (number >= table.len) return FitError.InvalidBaseType;
        const row = table[number];
        return .{
            .endian_ability = raw & 0x80 != 0, // bit 7
            .name = row.name,
            .invalid = row.invalid,
            .size = row.size,
            .number = number,
        };
    }
};

pub const Parser = struct {
    in: *Reader,
    header: FileHeader,
    definitions: [max_definitions]DefinitionMessage,
    data_read: u32,
    data_message_index: u32,

    pub fn init(in: *Reader) Parser {
        return .{
            .data_read = 0,
            .data_message_index = 1,
            .in = in,
            .header = undefined,
            .definitions = undefined,
        };
    }

    pub fn parseFile(self: *Parser) !void {
        try self.parseHeader();
        std.debug.print("FileHeader: {}\n", .{self.header});

        self.data_read = 0;
        while (self.data_read < self.header.data_size) {
            try self.parseRecord();
        }
        const crc = try self.in.takeInt(u16, .little);
        _ = crc; // TODO Read CRC
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
            _ = try self.in.take(size - 14);
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

    fn parseRecord(self: *Parser) !void {
        const header: RecordHeader = .decode(try self.in.takeByte());
        self.data_read += 1;

        // Decode Record Content
        switch (header) {
            .normal => |h| { // Normal Header
                if (h.is_definition) {
                    assert(!h.has_developer_data); // Cannot read developer data
                    try self.parseDefinitionMessage(h);
                } else {
                    try self.parseDataMessage(h);
                }
            },
            .compressed_timestamp => |h| {
                _ = h;
                unreachable; // Cannot read compressed timestamps yet
            },
        }
    }

    fn parseDefinitionMessage(self: *Parser, header: RecordHeader.Normal) !void {
        _ = try self.in.take(1); // skip reserved field
        const arch = try self.in.takeByte();
        const global_message_number = try self.in.takeInt(u16, try endian(arch));
        const num_fields = try self.in.takeByte();
        self.data_read += 5;

        var definition: DefinitionMessage = .{
            .arch = arch,
            .global_message_number = global_message_number,
            .num_fields = num_fields,
            .fields = undefined,
        };

        for (0..definition.num_fields) |i| {
            const field_definition_number = try self.in.takeByte();
            const size = try self.in.takeByte();
            const base_type = try self.in.takeByte(); // TODO: Decode accordng to Table 6.
            self.data_read += 3;

            const field: FieldDefinition = .{
                .field_definition_number = field_definition_number,
                .size = size,
                .base_type = try .decode(base_type),
            };

            definition.fields[i] = field;
        }

        // Save the message definition
        self.definitions[header.local_message_type] = definition;
    }

    fn parseDataMessage(self: *Parser, header: RecordHeader.Normal) !void {
        // Reserved in data messages and should be set to zero (false)
        assert(!header.has_developer_data);

        // Look up the local message type
        const definition = self.definitions[header.local_message_type];

        // Run through all data fields
        std.debug.print("{}. unknown_{}\n", .{ self.data_message_index, definition.global_message_number });
        self.data_message_index += 1;
        for (0..definition.num_fields) |i| {
            const field = definition.fields[i];

            std.debug.print(" * unknown_{}: {s} ", .{ field.field_definition_number, field.base_type.name });

            const elements = @divExact(field.size, field.base_type.size);
            for (0..elements) |j| {
                _ = j;
                switch (field.base_type.number) {
                    0 => { // enum
                        const value = try self.in.takeByte();
                        if (value == field.base_type.invalid) {
                            std.debug.print("None", .{});
                        } else {
                            std.debug.print("{}", .{value});
                        }
                    },
                    1 => { // sint8
                        const value = try self.in.takeInt(i8, .little);
                        if (value == field.base_type.invalid) {
                            std.debug.print("None", .{});
                        } else {
                            std.debug.print("{}", .{value});
                        }
                    },
                    2 => { // uint8
                        const value = try self.in.takeByte();
                        if (value == field.base_type.invalid) {
                            std.debug.print("None", .{});
                        } else {
                            std.debug.print("{}", .{value});
                        }
                    },
                    3 => { // sint16
                        const value = try self.in.takeInt(i16, try endian(definition.arch));
                        if (value == field.base_type.invalid) {
                            std.debug.print("None", .{});
                        } else {
                            std.debug.print("{}", .{value});
                        }
                    },
                    4 => { // uint16
                        const value = try self.in.takeInt(u16, try endian(definition.arch));
                        if (value == field.base_type.invalid) {
                            std.debug.print("None", .{});
                        } else {
                            std.debug.print("{}", .{value});
                        }
                    },
                    5 => { // sint32
                        const value = try self.in.takeInt(i32, try endian(definition.arch));
                        if (value == field.base_type.invalid) {
                            std.debug.print("None", .{});
                        } else {
                            std.debug.print("{}", .{value});
                        }
                    },
                    6 => { // uint32
                        const value = try self.in.takeInt(u32, try endian(definition.arch));
                        if (value == field.base_type.invalid) {
                            std.debug.print("None", .{});
                        } else {
                            std.debug.print("{}", .{value});
                        }
                    },
                    7 => { // string
                        const value = try self.in.takeByte();
                        if (value == field.base_type.invalid) {
                            std.debug.print("", .{});
                        } else {
                            std.debug.print("{c}", .{value});
                        }
                        // FIX: null terminated string
                    },
                    8 => { // float32
                        const value_int = try self.in.takeInt(u32, try endian(definition.arch));
                        if (value_int == field.base_type.invalid) {
                            std.debug.print("None", .{});
                        } else {
                            const value: f32 = @bitCast(value_int);
                            std.debug.print("{}", .{value});
                        }
                    },
                    9 => { // float64
                        const value_int = try self.in.takeInt(u64, try endian(definition.arch));
                        if (value_int == field.base_type.invalid) {
                            std.debug.print("None", .{});
                        } else {
                            const value: f64 = @bitCast(value_int);
                            std.debug.print("{}", .{value});
                        }
                    },
                    // TODO add the rest of the variants
                    else => {
                        _ = try self.in.take(field.base_type.size);
                    },
                }
                std.debug.print(", ", .{});
            }
            std.debug.print("\n", .{});
            self.data_read += field.size;
        }
    }
};

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

    try parser.parseRecord();
}

test "parse minimal" {
    var r: Reader = .fixed(&fit_file_short);
    var parser: Parser = .init(&r);
    try parser.parseFile();
}
