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
    InvalidMagic,
    InvalidArchitecture,
};

const max_definitions = 16;
const max_fields = 128;
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
    base_type: u8,
};

fn endian(arch: u8) !Endian {
    return switch (arch) {
        0 => .little,
        1 => .big,
        else => FitError.InvalidArchitecture,
    };
}

pub const Parser = struct {
    in: *Reader,
    header: FileHeader,
    definitions: [max_definitions]DefinitionMessage = undefined,
    data_read: u32,
    data_message_index: u32,

    pub fn init(in: *Reader) Parser {
        return .{
            .data_read = 0,
            .data_message_index = 1,
            .in = in,
            .header = undefined,
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
        std.debug.print("{}\n", .{header});

        // Decode Record Content
        switch (header) {
            .normal => |h| { // Normal Header
                if (h.is_definition) {
                    // No support for extended definition for developer data
                    assert(!h.has_developer_data);

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
                            .base_type = base_type,
                        };

                        definition.fields[i] = field;
                    }

                    // Save the message definition
                    std.debug.print("Saving {}\n", .{h.local_message_type});
                    self.definitions[h.local_message_type] = definition;
                } else { // Data Message
                    // Reserved in data messages and should be set to zero (false)
                    assert(!h.has_developer_data);

                    // Look up the local message type
                    const definition = self.definitions[h.local_message_type];

                    // Run through all data fields
                    std.debug.print("Data: {} {}\n", .{ self.data_message_index, definition.global_message_number });
                    self.data_message_index += 1;
                    for (0..definition.num_fields) |i| {
                        const field = definition.fields[i];
                        _ = try self.in.take(field.size);
                        self.data_read += field.size;
                    }
                }
            },
            .compressed_timestamp => |h| {
                _ = h;
                unreachable; // Cannot read compressed timestamps yet
            },
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

    // If I make a mistake here, the compiler doesn't point to the incorrect field.
    try testing.expectEqual(FileHeader{
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
