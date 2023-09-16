const std = @import("std");
const mem = std.mem;
const Allocator = mem.Allocator;
const Easy = @import("curl").Easy;

fn get(easy: Easy) !void {
    const resp = try easy.get("http://httpbin.org/anything");
    defer resp.deinit();

    std.debug.print("Status code: {d}\nBody: {s}\n", .{
        resp.status_code,
        resp.body.items,
    });

    // const date_header = try resp.get_header("date");
    // if (date_header) |h| {
    //     std.debug.print("date header: {s}\n", .{h.get()});
    // } else {
    //     std.debug.print("date header not found\n", .{});
    // }
}

fn post(easy: Easy) !void {
    var payload = std.io.fixedBufferStream(
        \\\ {"name": "John", "age": 15}
    );
    const resp = try easy.post("http://httpbin.org/anything", "application/json", payload.reader());
    defer resp.deinit();

    std.debug.print("Status code: {d}\nBody: {s}\n", .{
        resp.status_code,
        resp.body.items,
    });
}

pub fn main() !void {
    var arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    const easy = try Easy.init(allocator);
    defer easy.deinit();

    std.debug.print("-----------GET demo\n", .{});
    try get(easy);
    std.debug.print("-----------POST demo\n", .{});
    try post(easy);
}
