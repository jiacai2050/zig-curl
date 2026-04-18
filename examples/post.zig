const std = @import("std");
const curl = @import("curl");

pub fn main(init: std.process.Init) !void {
    var gpa = std.heap.DebugAllocator(.{}){};
    defer if (gpa.deinit() != .ok) @panic("leak");
    const allocator = gpa.allocator();

    var ca_bundle = try curl.allocCABundle(allocator, init.io);
    defer ca_bundle.deinit(allocator);
    var easy = try curl.Easy.init(.{
        .ca_bundle = ca_bundle,
    });
    defer easy.deinit();

    const payload =
        \\{"name": "John", "age": 15}
    ;

    var writer = std.Io.Writer.Allocating.init(allocator);
    defer writer.deinit();
    const response = try easy.fetch(
        "https://edgebin.liujiacai.net/anything",
        .{
            .method = .POST,
            .body = payload,
            .headers = &.{
                "Content-Type: application/json",
            },
            .writer = &writer.writer,
        },
    );

    std.debug.print("Status code: {d}\nBody: {s}\n", .{
        response.status_code,
        writer.writer.buffered(),
    });
}
