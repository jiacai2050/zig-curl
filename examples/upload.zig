const std = @import("std");
const println = @import("util.zig").println;
const curl = @import("curl");

const LOCAL_SERVER_ADDR = "http://localhost:8182";

pub fn main() !void {
    println("Upload demo");
    var gpa = std.heap.DebugAllocator(.{}){};
    defer if (gpa.deinit() != .ok) @panic("leak");
    const allocator = gpa.allocator();

    const easy = try curl.Easy.init(.{});
    defer easy.deinit();

    const path = "LICENSE";
    var writer = std.Io.Writer.Allocating.init(allocator);
    defer writer.deinit();

    const file = try std.fs.cwd().openFile(path, .{});
    defer file.close();

    var buf: [4096]u8 = undefined;
    var reader = file.reader(&buf);
    const resp = try easy.upload(LOCAL_SERVER_ADDR ++ "/anything", &reader.interface, &writer.writer);

    std.debug.print("Status code: {d}\nBody: {s}\n", .{
        resp.status_code,
        writer.writer.buffered(),
    });
}
