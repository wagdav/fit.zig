# FIT.zig

Decode [FIT](https://developer.garmin.com/fit/protocol/) files in Zig.

This is an experimental FIT library. I wrote it for myself to learn Zig. You should probably not use it.

## Usage

Specify the fields you want to extract from the FIT file as structs.  The struct's name is arbitrary, but the fields should match a field as defined in the global FIT profile.

```zig
const fit = @import("fit");

const Session = struct {
    sport: fit.Types.Sport,
    total_distance: f32,
    total_elapsed_time: f32,
};

const Record = struct {
    position_lat: ?i32,
    position_long: ?i32,
    altitude: ?f16,
    heart_rate: ?u8,
};
```

Construct a `fit.Parser` around an `std.Io.Reader` and iterate over the messages:

```zig
var parser: fit.Parser = .init(&reader);
var it = parser.messages();
while (try it.next()) |msg| switch (msg.message_number) {
    .session => std.debug.print("{}\n", .{
        try msg.decode(.session, Session),
    }),
    .record => std.debug.print("{}\n", .{
        try msg.decode(.record, Record),
    }),
    else => {
        // discard
    },
};
```

See [src/main.zig](src/main.zig) for a complete example.

The `decode` method takes two [comptime][ZigComptime] arguments and the Zig compiler generates code to fill-in the provided struct's fields.

If a field is not declared as optional, `decode` returns `FitError.MissingField`.

[ZigComptime]: https://ziglang.org/documentation/master/#comptime
