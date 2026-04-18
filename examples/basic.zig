const std = @import("std");
const curl = @import("curl");

const URL = "https://edgebin.liujiacai.net/anything";

pub fn main(init: std.process.Init) !void {
    var gpa: std.heap.DebugAllocator(.{}) = .init;
    defer if (gpa.deinit() != .ok) @panic("leak");
    const allocator = gpa.allocator();

    var ca_bundle = try curl.allocCABundle(allocator, init.io);
    defer ca_bundle.deinit(allocator);
    var easy = try curl.Easy.init(.{
        .ca_bundle = ca_bundle,
    });
    defer easy.deinit();

    {
        std.debug.print("GET without body\n", .{});
        const response = try easy.fetch(URL, .{});
        std.debug.print("Status code: {d}\n", .{response.status_code});
    }

    {
        std.debug.print("\nGET with fixed buffer as body\n", .{});
        var buffer: [1024]u8 = undefined;
        var writer = std.Io.Writer.fixed(&buffer);
        const response = try easy.fetch(URL, .{ .writer = &writer });
        std.debug.print("Status code: {d}\nBody: {s}\n", .{
            response.status_code,
            writer.buffered(),
        });
    }
}
