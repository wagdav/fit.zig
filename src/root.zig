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
const max_developer_fields = 256;

/// See Table 4 of https://developer.garmin.com/fit/protocol/
const DefinitionMessage = struct {
    arch: u8,
    global_message_number: u16,
    num_fields: u8,
    fields: [max_fields]FieldDefinition,
    num_developer_fields: u8,
    developer_fields: [max_developer_fields]DeveloperFieldDescription,
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

/// See Table 8 of https://developer.garmin.com/fit/protocol/
const DeveloperFieldDescription = struct {
    field_definition_number: u8,
    size: u8,
    developer_data_index: u8,
};

/// Global message ID 207
/// See Table 9 of https://developer.garmin.com/fit/protocol/
const DeveloperDataIdMessage = struct {
    application_id: [16]u8,
    developer_data_index: u8,
};

/// Global message ID 206
/// See Table 10 of https://developer.garmin.com/fit/protocol/
const FieldDescriptionMessage = struct {
    developer_data_index: u8,
    field_definition_number: u8,
    fit_base_type_id: u8,
    field_name: [64]u8,
    units: [16]u8,
    native_field_num: u8,
};

const max_definitions = 16;
const max_field_descriptions = 256;

pub const Parser = struct {
    in: *Reader,
    header: FileHeader,
    definitions: [max_definitions]DefinitionMessage,
    /// Developer field descriptions (global message 206) collected while
    /// parsing. Developer fields in data messages are decoded by looking up
    /// their (developer_data_index, field_definition_number) pair here.
    field_descriptions: [max_field_descriptions]FieldDescriptionMessage,
    num_field_descriptions: u8,
    data_read: u32,
    data_message_index: u32,

    pub fn init(in: *Reader) Parser {
        return .{
            .data_read = 0,
            .data_message_index = 1,
            .in = in,
            .header = undefined,
            .definitions = undefined,
            .field_descriptions = undefined,
            .num_field_descriptions = 0,
        };
    }

    fn lookupFieldDescription(self: *Parser, developer_data_index: u8, field_number: u8) ?FieldDescriptionMessage {
        for (0..self.num_field_descriptions) |i| {
            const d = self.field_descriptions[i];
            if (d.developer_data_index == developer_data_index and
                d.field_definition_number == field_number)
            {
                return d;
            }
        }
        return null;
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
            .num_developer_fields = 0,
            .developer_fields = undefined,
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

    fn parseDataMessage(self: *Parser, header: RecordHeader.Normal) !void {
        // In data messages and this should be set to zero (false)
        assert(!header.has_developer_data);

        // Look up the local message type
        const definition = self.definitions[header.local_message_type];

        // Field description messages (global message 206) declare the type,
        // name and units of developer fields. Capture them into the registry
        // so later developer fields can be decoded.
        if (definition.global_message_number == 206) {
            return self.parseFieldDescriptionMessage(definition);
        }

        // Print the data message type
        std.debug.print("{}. unknown_{}\n", .{ self.data_message_index, definition.global_message_number });
        self.data_message_index += 1;

        const en = try endian(definition.arch);

        // Run through all data fields
        for (0..definition.num_fields) |i| {
            const field = definition.fields[i];

            std.debug.print(" * unknown_{}: ", .{field.field_definition_number});
            try self.printField(field.base_type, field.size, en);
            std.debug.print("\n", .{});

            self.data_read += field.size;
        }

        // Developer fields carry no type in the definition; decode each one via
        // its field description, matched on (developer_data_index, field_number).
        for (0..definition.num_developer_fields) |i| {
            const field = definition.developer_fields[i];

            if (self.lookupFieldDescription(field.developer_data_index, field.field_definition_number)) |desc| {
                const base_type = try BaseType.decode(desc.fit_base_type_id);
                std.debug.print(" * {s}: ", .{std.mem.sliceTo(&desc.field_name, 0)});
                try self.printField(base_type, field.size, en);

                const units = std.mem.sliceTo(&desc.units, 0);
                if (units.len > 0) std.debug.print(" [{s}]", .{units});
                std.debug.print("\n", .{});
            } else {
                // No description was seen for this field; skip its bytes.
                std.debug.print(" * developer_{}_{}: ???\n", .{ field.developer_data_index, field.field_definition_number });
                _ = try self.in.take(field.size);
            }

            self.data_read += field.size;
        }
    }

    /// Parse a field description message (global message 206, Table 10) and add
    /// it to the registry. Fields are read according to the definition and
    /// dispatched by their field definition number.
    fn parseFieldDescriptionMessage(self: *Parser, definition: DefinitionMessage) !void {
        var desc: FieldDescriptionMessage = std.mem.zeroes(FieldDescriptionMessage);

        for (0..definition.num_fields) |i| {
            const field = definition.fields[i];
            switch (field.field_definition_number) {
                0 => desc.developer_data_index = try self.in.takeByte(),
                1 => desc.field_definition_number = try self.in.takeByte(),
                2 => desc.fit_base_type_id = try self.in.takeByte(),
                3 => @memcpy(desc.field_name[0..field.size], try self.in.take(field.size)),
                8 => @memcpy(desc.units[0..field.size], try self.in.take(field.size)),
                15 => desc.native_field_num = try self.in.takeByte(),
                else => _ = try self.in.take(field.size),
            }
            self.data_read += field.size;
        }

        self.field_descriptions[self.num_field_descriptions] = desc;
        self.num_field_descriptions += 1;
    }

    /// Read a single field value (possibly an array) and print it.
    fn printField(self: *Parser, base_type: BaseType, size: u8, en: Endian) !void {
        const invalid = base_type.invalid();

        // special case for strings
        if (base_type == .string) {
            const bytes = try self.in.take(size);
            std.debug.print("{s}", .{std.mem.sliceTo(bytes, 0)});
            return;
        }

        const elements = @divExact(size, base_type.size());
        const is_array = elements > 1;

        if (is_array) std.debug.print("(", .{}); // opening paren

        for (0..elements) |j| {
            switch (base_type) {
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

test "parse figure 14" {
    var r: Reader = .fixed(&fit_file_figure_14);
    var parser: Parser = .init(&r);

    try parser.parseFile();

    try testing.expectEqual(14, parser.header.size);
    try testing.expectEqual(222, parser.header.data_size);
    try testing.expectEqualSlices(u8, ".FIT", &parser.header.data_type);
}
