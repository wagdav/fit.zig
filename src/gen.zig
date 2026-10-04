//! `gen` - generate FIT profile from Garmin's FIT JavaScript SDK `profile.js`:
//!
//!     zig build gen < fit-javascript-sdk/src/profile.js > src/profile.generated.zig
//!
//! `profile.js` is machine-generated with fixed indentation, so it is parsed
//! line by line: each section is cut out by its header line, and within a
//! section the indentation tells what a `key: value,` line belongs to.
//! Anything unexpected (an unknown base type, a missing section, an
//! out-of-range number) is an error rather than silently generating wrong
//! code.

const std = @import("std");
const Io = std.Io;
const Allocator = std.mem.Allocator;

pub fn main(init: std.process.Init) !void {
    const arena = init.arena.allocator();

    var stdin_buffer: [4096]u8 = undefined;
    var stdin_reader: Io.File.Reader = .init(.stdin(), init.io, &stdin_buffer);
    const src = try stdin_reader.interface.allocRemaining(arena, .unlimited);

    var stdout_buffer: [4096]u8 = undefined;
    var stdout_writer: Io.File.Writer = .init(.stdout(), init.io, &stdout_buffer);
    const out = &stdout_writer.interface;

    const profile: Profile = .{
        .version = try parseVersion(try section(src, "    version: {")),
        .messages = try parseMessages(arena, try section(src, "    messages: {")),
        .types = try parseTypes(arena, try section(src, "types: {")),
    };
    try emit(arena, out, profile);
    try out.flush();
}

// ---------------------------------------------------------------------------
// Model. Names are already converted to Zig style (snake_case / PascalCase).

const Profile = struct {
    version: Version,
    messages: []const Message,
    types: []const EnumType,
};

const Version = struct {
    major: u32,
    minor: u32,
    patch: u32,
    type: []const u8,
};

const Message = struct {
    number: u16,
    name: []const u8,
    fields: []const Field,
};

const Field = struct {
    number: u8,
    name: []const u8,
    /// The Zig type expression, e.g. `u16`, `types.File`, `[]const i32`.
    type: []const u8,
    /// The referenced `types.*` enum, as named in profile.js; null when the
    /// field decodes to its carrier type.
    enum_type: ?[]const u8,
    is_date_time: bool,
    scale: ?[]const u8,
    offset: ?[]const u8,
    units: ?[]const u8,
};

const EnumType = struct {
    /// The name as used in profile.js (camelCase), matched against
    /// `Field.enum_type`.
    js_name: []const u8,
    /// Whether profile.js lists a value that does not fit `enum(u8)` (32-bit
    /// flag sets such as `connectivityCapabilities`). Such a type must not be
    /// referenced by an `enum`-based field.
    has_wide_values: bool = false,
    /// Tag name by value. A value listed twice in profile.js (weatherReport's
    /// deprecated `forecast` and `hourlyForecast` are both 1) keeps the last
    /// entry, as the JS object literal does.
    tags: [256]?[]const u8,
};

// ---------------------------------------------------------------------------
// Parsing.

/// The lines of the section opened by `header` (a whole line, including its
/// indentation), up to the first line indented no deeper than the header that
/// either closes it (`}`) or opens a sibling (`... {`). profile.js is not
/// indented consistently enough to match the closing brace's depth exactly:
/// `messages` closes at column 0 and `types` at column 3.
fn section(src: []const u8, comptime header: []const u8) ![]const u8 {
    const start = (std.mem.indexOf(u8, src, "\n" ++ header ++ "\n") orelse return error.MissingSection) + header.len + 2;
    const header_indent = header.len - std.mem.trimStart(u8, header, " ").len;
    var pos = start;
    while (std.mem.indexOfScalarPos(u8, src, pos, '\n')) |nl| : (pos = nl + 1) {
        const text = std.mem.trimStart(u8, src[pos..nl], " ");
        const indent = nl - pos - text.len;
        if (indent <= header_indent and
            (std.mem.startsWith(u8, text, "}") or std.mem.endsWith(u8, text, "{"))) return src[start..pos];
    }
    return error.UnclosedSection;
}

const Line = struct {
    indent: usize,
    key: []const u8,
    /// The value with any trailing comment and comma removed.
    value: []const u8,

    /// Parse a `key: value,` line; null for lines that are not key/value
    /// (closing braces, array elements).
    fn parse(raw: []const u8) ?Line {
        const text = std.mem.trimStart(u8, raw, " ");
        const colon = std.mem.indexOfScalar(u8, text, ':') orelse return null;
        var value = text[colon + 1 ..];
        if (std.mem.indexOf(u8, value, "//")) |comment| value = value[0..comment];
        return .{
            .indent = raw.len - text.len,
            .key = text[0..colon],
            .value = std.mem.trimEnd(u8, std.mem.trim(u8, value, " \r"), ","),
        };
    }
};

fn unquote(s: []const u8) ![]const u8 {
    if (s.len < 2 or s[0] != '"' or s[s.len - 1] != '"') return error.ExpectedString;
    return s[1 .. s.len - 1];
}

fn parseVersion(lines: []const u8) !Version {
    var major: ?u32 = null;
    var minor: ?u32 = null;
    var patch: ?u32 = null;
    var release_type: ?[]const u8 = null;
    var it = std.mem.splitScalar(u8, lines, '\n');
    while (it.next()) |raw| {
        const line = Line.parse(raw) orelse continue;
        const Key = enum { major, minor, patch, type };
        switch (std.meta.stringToEnum(Key, line.key) orelse return error.UnknownVersionKey) {
            .major => major = try std.fmt.parseInt(u32, line.value, 10),
            .minor => minor = try std.fmt.parseInt(u32, line.value, 10),
            .patch => patch = try std.fmt.parseInt(u32, line.value, 10),
            .type => release_type = try unquote(line.value),
        }
    }
    return .{
        .major = major orelse return error.MissingVersion,
        .minor = minor orelse return error.MissingVersion,
        .patch = patch orelse return error.MissingVersion,
        .type = release_type orelse return error.MissingVersion,
    };
}

/// Messages: `num`/`name` at indent 12, their fields' keys at indent 16.
/// Deeper lines (sub-fields, components) are not part of the RawField model.
fn parseMessages(arena: Allocator, lines: []const u8) ![]const Message {
    var messages: std.ArrayList(Message) = .empty;
    var fields: std.ArrayList(Field) = .empty;
    var field: RawFieldLines = .{};

    var it = std.mem.splitScalar(u8, lines, '\n');
    while (it.next()) |raw| {
        const line = Line.parse(raw) orelse continue;
        switch (line.indent) {
            12 => if (std.mem.eql(u8, line.key, "num")) {
                if (messages.items.len > 0) try closeMessage(arena, &messages, &fields, field);
                try messages.append(arena, .{
                    .number = try std.fmt.parseInt(u16, line.value, 10),
                    .name = "",
                    .fields = &.{},
                });
                field = .{};
            } else if (std.mem.eql(u8, line.key, "name")) {
                if (messages.items.len == 0) return error.NameBeforeNum;
                messages.items[messages.items.len - 1].name = try snakeCase(arena, try unquote(line.value));
            },
            16 => {
                if (std.mem.eql(u8, line.key, "num") and field.num != null) {
                    try fields.append(arena, try field.finish(arena));
                    field = .{};
                }
                try field.set(line);
            },
            else => {},
        }
    }
    if (messages.items.len == 0) return error.NoMessages;
    try closeMessage(arena, &messages, &fields, field);
    return messages.items;
}

/// Finish the last message: append its pending field (if it has any fields at
/// all) and move the collected fields into it.
fn closeMessage(arena: Allocator, messages: *std.ArrayList(Message), fields: *std.ArrayList(Field), pending: RawFieldLines) !void {
    if (pending.num != null) try fields.append(arena, try pending.finish(arena));
    messages.items[messages.items.len - 1].fields = try fields.toOwnedSlice(arena);
}

/// The raw `key: value` strings of one field, collected until the field is
/// complete and can be turned into a `Field`.
const RawFieldLines = struct {
    num: ?[]const u8 = null,
    name: ?[]const u8 = null,
    type: ?[]const u8 = null,
    baseType: ?[]const u8 = null,
    array: ?[]const u8 = null,
    scale: ?[]const u8 = null,
    offset: ?[]const u8 = null,
    units: ?[]const u8 = null,

    fn set(self: *RawFieldLines, line: Line) !void {
        const info = @typeInfo(RawFieldLines).@"struct";
        inline for (info.field_names) |field_name| {
            if (std.mem.eql(u8, line.key, field_name)) {
                if (@field(self, field_name) != null) return error.DuplicateFieldKey;
                @field(self, field_name) = line.value;
            }
        }
    }

    fn finish(self: RawFieldLines, arena: Allocator) !Field {
        const js_type = try unquote(self.type orelse return error.MissingFieldKey);
        const base_type = try unquote(self.baseType orelse return error.MissingFieldKey);
        const is_array = std.mem.eql(u8, self.array orelse return error.MissingFieldKey, "true");

        // Only `enum`-based named types become generated enums; everything
        // else (dateTime, manufacturer, bool, ...) decodes to its carrier.
        const is_enum = std.mem.eql(u8, base_type, "enum") and
            !std.mem.eql(u8, js_type, "enum") and !std.mem.eql(u8, js_type, "bool");
        const element = if (is_enum)
            try std.fmt.allocPrint(arena, "types.{s}", .{try pascalCase(arena, js_type)})
        else
            carriers.get(base_type) orelse return error.UnknownBaseType;
        // A string is already a slice; its `array` flag means "of characters".
        const zig_type = if (is_array and !std.mem.eql(u8, base_type, "string"))
            try std.fmt.allocPrint(arena, "[]const {s}", .{element})
        else
            element;

        const scale = try scalar(self.scale orelse return error.MissingFieldKey);
        const offset = try scalar(self.offset orelse return error.MissingFieldKey);
        const units = if (try scalar(self.units orelse return error.MissingFieldKey)) |u| try unquote(u) else null;
        return .{
            .number = try std.fmt.parseInt(u8, self.num orelse return error.MissingFieldKey, 10),
            .name = try snakeCase(arena, try unquote(self.name orelse return error.MissingFieldKey)),
            .type = zig_type,
            .enum_type = if (is_enum) js_type else null,
            .is_date_time = std.mem.eql(u8, js_type, "dateTime") or std.mem.eql(u8, js_type, "localDateTime"),
            // Omit the identity defaults so the tables only state what matters.
            .scale = if (scale) |s| if (std.mem.eql(u8, s, "1")) null else s else null,
            .offset = if (offset) |o| if (std.mem.eql(u8, o, "0")) null else o else null,
            .units = if (units) |u| if (u.len == 0) null else u else null,
        };
    }
};

/// Zig carrier type for each FIT base type.
const carriers: std.StaticStringMap([]const u8) = .initComptime(.{
    .{ "enum", "u8" },     .{ "sint8", "i8" },          .{ "uint8", "u8" },
    .{ "uint8z", "u8" },   .{ "byte", "u8" },           .{ "sint16", "i16" },
    .{ "uint16", "u16" },  .{ "uint16z", "u16" },       .{ "sint32", "i32" },
    .{ "uint32", "u32" },  .{ "uint32z", "u32" },       .{ "sint64", "i64" },
    .{ "uint64", "u64" },  .{ "uint64z", "u64" },       .{ "float32", "f32" },
    .{ "float64", "f64" }, .{ "string", "[]const u8" },
});

/// The field's own value of a scale/offset/units entry. Fields with components
/// list one value per component (`[5, ]`, `["m/s", "m", ]`); the first applies
/// to the field itself. Returns null for a multi-valued scale/offset list,
/// whose values only apply to the components.
fn scalar(value: []const u8) !?[]const u8 {
    if (!std.mem.startsWith(u8, value, "[")) return value;
    var it = std.mem.tokenizeAny(u8, value, "[], ");
    const first = it.next() orelse return error.EmptyList;
    // Units are per component too, but the field keeps the first one.
    if (it.next() != null and first[0] != '"') return null;
    return first;
}

/// Types: a type name at indent 3, its `value: "name",` entries deeper
/// (usually 7, but not always).
fn parseTypes(arena: Allocator, lines: []const u8) ![]const EnumType {
    var types: std.ArrayList(EnumType) = .empty;
    var it = std.mem.splitScalar(u8, lines, '\n');
    while (it.next()) |raw| {
        const line = Line.parse(raw) orelse continue;
        switch (line.indent) {
            0...2 => return error.UnexpectedIndent,
            3 => try types.append(arena, .{ .js_name = line.key, .tags = @splat(null) }),
            else => {
                if (types.items.len == 0) return error.ValueBeforeType;
                const t = &types.items[types.items.len - 1];
                const value = std.fmt.parseInt(u8, line.key, 0) catch |err| switch (err) {
                    error.Overflow => {
                        t.has_wide_values = true;
                        continue;
                    },
                    else => return err,
                };
                t.tags[value] = try snakeCase(arena, try unquote(line.value));
            },
        }
    }
    return types.items;
}

/// camelCase -> snake_case.
fn snakeCase(arena: Allocator, s: []const u8) ![]const u8 {
    var out: std.ArrayList(u8) = .empty;
    for (s, 0..) |c, i| {
        if (std.ascii.isUpper(c) and i > 0) try out.append(arena, '_');
        try out.append(arena, std.ascii.toLower(c));
    }
    return out.items;
}

/// camelCase -> PascalCase.
fn pascalCase(arena: Allocator, s: []const u8) ![]const u8 {
    const out = try arena.dupe(u8, s);
    out[0] = std.ascii.toUpper(out[0]);
    return out;
}

// ---------------------------------------------------------------------------
// Emitting.

fn emit(arena: Allocator, out: *Io.Writer, p: Profile) !void {
    try out.print(
        \\//! The FIT Global Profile, as comptime tables.
        \\//!
        \\//! GENERATED by `zig build gen < profile.js` from Garmin's FIT
        \\//! JavaScript SDK. Do not edit by hand. Lookup helpers live in
        \\//! `profile.zig`.
        \\
        \\const std = @import("std");
        \\const RawField = @import("profile.zig").RawField;
        \\
        \\/// Version of the FIT Global Profile this file was generated from.
        \\pub const version: std.SemanticVersion = .{{ .major = {d}, .minor = {d}, .patch = {d} }};
        \\/// Release type of the profile (e.g. "Release").
        \\pub const version_type = "{f}";
        \\
    , .{ p.version.major, p.version.minor, p.version.patch, std.zig.fmtString(p.version.type) });

    try out.writeAll(
        \\
        \\/// Enumerated types referenced by `enum`-based fields. All are
        \\/// non-exhaustive: unnamed wire values decode to an unnamed tag.
        \\pub const types = struct {
        \\
    );
    for (p.types) |t| {
        if (!isReferenced(p.messages, t.js_name)) continue;
        if (t.has_wide_values) return error.EnumValueOutOfRange;
        try out.print("    pub const {s} = enum(u8) {{\n", .{try pascalCase(arena, t.js_name)});
        for (t.tags, 0..) |tag, value| {
            if (tag) |name| try out.print("        {f} = {d},\n", .{ std.zig.fmtId(name), value });
        }
        try out.writeAll("        _,\n    };\n");
    }
    try out.writeAll("};\n");

    try out.writeAll(
        \\
        \\/// Global message number. Non-exhaustive: any unrecognized number decodes to an
        \\/// unnamed value, which a `switch (msg.message_number)` handles via `else`.
        \\pub const MesgNum = enum(u16) {
        \\
    );
    for (p.messages) |m| try out.print("    {f} = {d},\n", .{ std.zig.fmtId(m.name), m.number });
    try out.writeAll("    _,\n};\n");

    for (p.messages) |m| {
        try out.print("\npub const {f}: []const RawField = &.{{", .{std.zig.fmtId(m.name)});
        if (m.fields.len > 0) try out.writeAll("\n");
        for (m.fields) |f| {
            try out.print("    .{{ .number = {d}, .name = \"{s}\", .type = {s}", .{ f.number, f.name, f.type });
            if (f.scale) |s| try out.print(", .scale = {s}", .{s});
            if (f.offset) |o| try out.print(", .offset = {s}", .{o});
            if (f.units) |u| try out.print(", .units = \"{f}\"", .{std.zig.fmtString(u)});
            try out.writeAll(if (f.is_date_time) " }, // date_time carrier\n" else " },\n");
        }
        try out.writeAll("};\n");
    }
}

/// Whether any field decodes to the enum type `js_name`.
fn isReferenced(messages: []const Message, js_name: []const u8) bool {
    for (messages) |m| for (m.fields) |f| {
        if (f.enum_type) |t| if (std.mem.eql(u8, t, js_name)) return true;
    };
    return false;
}
