const std = @import("std");
const curl = @import("curl");

pub fn main() !void {
    var gpa = std.heap.DebugAllocator(.{}){};
    defer if (gpa.deinit() != .ok) @panic("leak");
    const allocator = gpa.allocator();

    const ca_bundle = try curl.allocCABundle(allocator);
    defer ca_bundle.deinit();
    const easy = try curl.Easy.init(.{
        .ca_bundle = ca_bundle,
    });
    defer easy.deinit();

    const payload =
        \\{"name": "John", "age": 15}
    ;

    var writer = std.Io.Writer.Allocating.init(allocator);
    defer writer.deinit();
    const resp = try easy.fetch(
        "https://httpbin.liujiacai.net/anything",
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
        resp.status_code,
        writer.writer.buffered(),
    });
}
