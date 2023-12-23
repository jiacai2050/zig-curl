const std = @import("std");
const println = @import("util.zig").println;
const mem = std.mem;
const Allocator = mem.Allocator;
const curl = @import("curl");
const Easy = curl.Easy;

fn get(easy: Easy) !void {
    const resp = try easy.get("https://httpbin.org/anything");
    defer resp.deinit();

    std.debug.print("Status code: {d}\nBody: {s}\n", .{
        resp.status_code,
        resp.body.items,
    });
}

fn post(easy: Easy) !void {
    var payload = std.io.fixedBufferStream(
        \\{"name": "John", "age": 15}
    );
    const resp = try easy.post("https://httpbin.org/anything", "application/json", payload.reader());
    defer resp.deinit();

    std.debug.print("Status code: {d}\nBody: {s}\n", .{
        resp.status_code,
        resp.body.items,
    });
}

pub fn main() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer if (gpa.deinit() != .ok) @panic("leak");
    const allocator = gpa.allocator();

    const easy = try Easy.init(allocator, .{});
    defer easy.deinit();

    println("GET demo");
    try get(easy);

    println("POST demo");
    try post(easy);
}
