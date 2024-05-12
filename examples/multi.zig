const std = @import("std");
const println = @import("util.zig").println;
const mem = std.mem;
const Allocator = mem.Allocator;
const curl = @import("curl");
const Easy = curl.Easy;
const Multi = curl.Multi;
const c = curl.libcurl;

pub fn main() !void {
    const allocator = std.heap.page_allocator;

    const multi = try Multi.init();
    defer multi.deinit();

    const easy = try Easy.init(allocator, .{});
    try easy.setUrl("http://httpbin.org/headers");
    try multi.addHandle(easy);

    const easy2 = try Easy.init(allocator, .{});
    try easy2.setUrl("http://httpbin.org/ip");
    try multi.addHandle(easy2);

    var running = true;
    while (running) {
        const transfer = try multi.perform();
        running = transfer != 0;
        std.debug.print("num of transfer {any}\n", .{transfer});

        const num_fds = try multi.poll(null, 3000);
        std.debug.print("ret = {any}\n", .{num_fds});
    }

    running = true;
    while (running) {
        const info = try multi.readInfo();
        running = info.msgs_in_queue != 0;
        try multi.removeHandle(info.msg.easy_handle.?);
        c.curl_easy_cleanup(info.msg.easy_handle.?);
        std.debug.print("info {any}\n", .{info});
    }
}
