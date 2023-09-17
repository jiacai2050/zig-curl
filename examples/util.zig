const std = @import("std");

const SEP = "-" ** 20;

pub fn println(msg: []const u8) void {
    std.debug.print("{s}{s}{s}\n", .{ SEP, msg, SEP });
}
