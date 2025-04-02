const std = @import("std");
const println = @import("util.zig").println;
const mem = std.mem;
const Allocator = mem.Allocator;
const curl = @import("curl");
const Easy = curl.Easy;
const Multi = curl.Multi;
const c = curl.libcurl;
const checkCode = curl.checkCode;
const Buffer = std.ArrayList(u8);

pub fn main() !void {
    const allocator = std.heap.page_allocator;

    const multi = try Multi.init();
    defer multi.deinit();

    const easy1 = try Easy.init(allocator, .{});
    try easy1.setUrl("http://httpbin.org/headers");
    var buf1 = Buffer.init(allocator);
    try easy1.setWritedata(&buf1);
    try easy1.setWritefunction(Easy.bufferWriteCallback);
    try multi.addHandle(easy1);

    const easy2 = try Easy.init(allocator, .{});
    try easy2.setUrl("http://httpbin.org/ip");
    var buf2 = Buffer.init(allocator);
    try easy2.setWritedata(&buf2);
    try easy2.setWritefunction(Easy.bufferWriteCallback);
    try multi.addHandle(easy2);

    var pending_requests: c_int = 2;
    while (pending_requests > 0) {
        pending_requests = try multi.perform();
        std.debug.print("{d} pending requests...\n", .{pending_requests});

        // This will block for up to 100ms waiting for activity
        const num_fds = try multi.poll(null, 100);
        std.debug.print("{d} requests had activity...\n", .{num_fds});

        const info = multi.readInfo() catch |e| switch (e) {
            // no new data to read on this iteration
            error.InfoReadExhausted => continue,
        };

        // If we have `info` then one of the requests completed
        const easy_handle = info.msg.easy_handle.?;

        // check that the request was successful
        try checkCode(info.msg.data.result);

        // Read the HTTP status code
        var status_code: c_long = 0;
        try checkCode(c.curl_easy_getinfo(easy_handle, c.CURLINFO_RESPONSE_CODE, &status_code));
        std.debug.print("Return Code: {any}\n", .{status_code});

        // Read the Response body
        const buf = b: {
            if (easy_handle == easy1.handle) {
                break :b buf1;
            } else if (easy_handle == easy2.handle) {
                break :b buf2;
            }
            unreachable;
        };
        std.debug.print("Body: {s}\n", .{buf.items});

        try multi.removeHandle(easy_handle);

        c.curl_easy_cleanup(easy_handle);
        // Note: there is also `curl_easy_reset` if you want to reuse the handle
        // for another request
    }
}
