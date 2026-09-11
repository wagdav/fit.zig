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
};

const max_fields = 256;

/// See Table 4 of https://developer.garmin.com/fit/protocol/
const DefinitionMessage = struct {
    arch: u8,
    global_message_number: u16,
    num_fields: u8,
    fields: [max_fields]FieldDefinition,
};

/// See Table 5 of https://developer.garmin.com/fit/protocol/
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

        // Print the data message type
        std.debug.print("{}. unknown_{}\n", .{ self.data_message_index, definition.global_message_number });
        self.data_message_index += 1;

        const en = try endian(definition.arch);

        // Run through all data fields
        for (0..definition.num_fields) |i| {
            const field = definition.fields[i];
            const invalid = field.base_type.invalid();

            std.debug.print(" * unknown_{}: ", .{field.field_definition_number});

            const elements = @divExact(field.size, field.base_type.size());
            const is_array = elements > 1;

            // special case for strings
            if (field.base_type == .string) {
                const bytes = try self.in.take(field.size);
                const s = std.mem.sliceTo(bytes, 0);
                std.debug.print("{s}", .{s});
            } else {
                if (is_array) std.debug.print("(", .{}); // opening paren

                for (0..elements) |j| {
                    switch (field.base_type) {
                        .enum_ => printOptional(try self.takeField(u8, en, invalid)),
                        .sint8 => printOptional(try self.takeField(i8, en, invalid)),
                        .uint8 => printOptional(try self.takeField(u8, en, invalid)),
                        .sint16 => printOptional(try self.takeField(i16, en, invalid)),
                        .uint16 => printOptional(try self.takeField(u16, en, invalid)),
                        .sint32 => printOptional(try self.takeField(i32, en, invalid)),
                        .uint32 => printOptional(try self.takeField(u32, en, invalid)),
                        .string => {}, // already handled
                        .float32 => printOptional(try self.takeField(f32, en, invalid)),
                        .float64 => printOptional(try self.takeField(f64, en, invalid)),
                        .uint8z => printOptional(try self.takeField(u8, en, invalid)),
                        .uint16z => printOptional(try self.takeField(u16, en, invalid)),
                        .uint32z => printOptional(try self.takeField(u32, en, invalid)),
                        .byte => printOptional(try self.takeField(u8, en, invalid)),
                        .sint64 => printOptional(try self.takeField(i64, en, invalid)),
                        .uint64 => printOptional(try self.takeField(u64, en, invalid)),
                        .uint64z => printOptional(try self.takeField(u64, en, invalid)),
                    }
                    if (is_array) {
                        if (j < elements - 1) std.debug.print(", ", .{}); // separator
                        if (j == elements - 1) std.debug.print(")", .{}); // closing paren
                    }
                }
            }
            std.debug.print("\n", .{});
            self.data_read += field.size;
        }
    }

    fn takeField(self: *Parser, comptime T: type, en: Endian, invalid: u64) !?T {
        switch (@typeInfo(T)) {
            .int => {
                const value = try self.in.takeInt(T, en);
                return if (value == invalid) null else value;
            },
            .float => {
                const Bits = @Int(.unsigned, @bitSizeOf(T));
                const bits = try self.in.takeInt(Bits, en);
                return if (bits == invalid) null else @bitCast(bits);
            },
            else => unreachable,
        }
    }
};

fn printOptional(value: anytype) void {
    if (value) |v| {
        std.debug.print("{d}", .{v});
    } else {
        std.debug.print("None", .{});
    }
}

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
