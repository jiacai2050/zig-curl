const std = @import("std");
const println = @import("util.zig").println;
const mem = std.mem;
const Allocator = mem.Allocator;
const curl = @import("curl");
const Easy = curl.Easy;
const Multi = curl.Multi;
const c = curl.libcurl;

pub fn main() !void {
    var arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    const easy = try Easy.init(allocator, .{});
    try easy.set_url("http://httpbin.org/headers");
    defer easy.deinit();

    const multi = try Multi.init();
    // defer multi.deinit();

    try multi.addHandle(easy.handle);

    var running = true;
    const transfer = try multi.perform();
    std.debug.print("num of transfer {any}\n", .{transfer});

    while (running) {
        const info = try multi.readInfo();
        running = info.msgs_in_queue != 0;
        try multi.removeHandle(info.msg.easy_handle.?);
        c.curl_easy_cleanup(info.msg.easy_handle.?);
        std.debug.print("{any}\n", .{info});
    }
}
