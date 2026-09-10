const std = @import("std");
const Io = std.Io;

const fit = @import("fit_zig");

pub fn main(init: std.process.Init) !void {
    const io = init.io;

    var stdin_buffer: [1024]u8 = undefined;
    var stdin_file_reader: Io.File.Reader = .init(.stdin(), io, &stdin_buffer);
    const stdin_reader = &stdin_file_reader.interface;

    var parser: fit.Parser = .init(stdin_reader);
    try parser.parseFile();
}
