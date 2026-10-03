const std = @import("std");
const curl = @import("curl");

const URL = "https://edgebin.liujiacai.net/anything";

pub fn main(init: std.process.Init) !void {
    var gpa: std.heap.DebugAllocator(.{}) = .init;
    defer if (gpa.deinit() != .ok) @panic("memory leak detected");
    const allocator = gpa.allocator();

    var ca_bundle = try curl.allocCABundle(allocator, init.io);
    defer ca_bundle.deinit(allocator);

    var easy = try curl.Easy.init(.{
        .ca_bundle = ca_bundle,
    });
    defer easy.deinit();

    var buffer: [2048]u8 = undefined;
    var writer = std.Io.Writer.fixed(&buffer);
    const response = try easy.fetch(URL, .{ .writer = &writer });

    std.debug.print("Downstream GET response status: {d}\n", .{response.status_code});
    if (response.status_code != 200) {
        return error.UnexpectedStatusCode;
    }
}
