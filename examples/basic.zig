const std = @import("std");
const println = @import("util.zig").println;
const mem = std.mem;
const Allocator = mem.Allocator;
const curl = @import("curl");
const Easy = curl.Easy;

pub fn main() !void {
    var gpa: std.heap.DebugAllocator(.{}) = .init;
    defer if (gpa.deinit() != .ok) @panic("leak");
    const allocator = gpa.allocator();

    const ca_bundle = try curl.allocCABundle(allocator);
    defer ca_bundle.deinit();
    const easy = try Easy.init(.{
        .ca_bundle = ca_bundle,
    });
    defer easy.deinit();
    {
        println("GET without write context");
        const resp = try easy.fetch("https://httpbin.org/anything", .{});

        std.debug.print("Status code: {d}\n", .{resp.status_code});
    }

    {
        println("GET with fixed buffer");
        var buffer: [1024]u8 = undefined;
        var writer = std.Io.Writer.fixed(&buffer);
        const resp = try easy.fetch("https://httpbin.org/anything", .{
            .writer = &writer,
        });
        std.debug.print("Status code: {d}\nBody: {s}\n", .{
            resp.status_code,
            writer.buffered(),
        });
    }
}
