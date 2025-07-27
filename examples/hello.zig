const std = @import("std");
const curl = @import("curl");

pub fn main() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer if (gpa.deinit() != .ok) @panic("leak");
    const allocator = gpa.allocator();

    const ca_bundle = try curl.allocCABundle(allocator);
    defer ca_bundle.deinit();
    const easy = try curl.Easy.init(.{
        .ca_bundle = ca_bundle,
    });
    defer easy.deinit();

    var ctx = curl.ResizableWriteContext.init(allocator);
    defer ctx.deinit();
    const resp = try easy.fetch("https://httpbin.org/anything", .{}, &ctx);

    std.debug.print("Status code: {d}\nBody: {s}\n", .{
        resp.status_code,
        ctx.asSlice(),
    });
}
