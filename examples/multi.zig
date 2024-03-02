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

    const ca_bundle = try curl.allocCABundle(allocator);
    defer ca_bundle.deinit();
    const easy = try Easy.init(allocator, .{
        .ca_bundle = ca_bundle,
    });
    try easy.set_url("http://httpbin.org/headers");
    defer easy.deinit();

    const easy2 = try Easy.init(allocator, .{
        .ca_bundle = ca_bundle,
    });
    try easy2.set_url("http://httpbin.org/ip");
    defer easy2.deinit();

    const multi = try Multi.init();
    // defer multi.deinit();

    try multi.addHandle(easy);
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
