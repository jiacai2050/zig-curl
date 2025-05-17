const std = @import("std");
const println = @import("util.zig").println;
const mem = std.mem;
const Allocator = mem.Allocator;
const curl = @import("curl");
const Easy = curl.Easy;
const Multi = curl.Multi;
const c = curl.libcurl;
const checkCode = curl.checkCode;
const Buffer = curl.Buffer;

pub fn main() !void {
    const allocator = std.heap.page_allocator;

    const multi = try Multi.init();
    defer multi.deinit();

    const easy1 = try Easy.init(allocator, .{});
    try easy1.setUrl("http://httpbin.org/headers");
    var buf1 = Buffer.init(allocator);
    defer buf1.deinit();
    try easy1.setWritedata(&buf1);
    try easy1.setWritefunction(Easy.bufferWriteCallback);
    // CURLOPT_PRIVATE allows us to store a pointer to the buffer in the easy handle
    // so we can retrieve it later in the callback. Otherwise we would need to keep
    // a hashmap of which handle goes with which buffer.
    try checkCode(c.curl_easy_setopt(easy1.handle, c.CURLOPT_PRIVATE, &buf1));
    try multi.addHandle(easy1);

    const easy2 = try Easy.init(allocator, .{});
    try easy2.setUrl("http://httpbin.org/ip");
    var buf2 = Buffer.init(allocator);
    defer buf2.deinit();
    try easy2.setWritedata(&buf2);
    try easy2.setWritefunction(Easy.bufferWriteCallback);
    try checkCode(c.curl_easy_setopt(easy2.handle, c.CURLOPT_PRIVATE, &buf2));
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
        std.debug.print("Response Code: {any}\n", .{status_code});

        // Get the private data (buffer) associated with this handle
        var private_data: ?*anyopaque = null;
        try checkCode(c.curl_easy_getinfo(easy_handle, c.CURLINFO_PRIVATE, &private_data));
        const buf = @as(*Buffer, @ptrCast(@alignCast(private_data.?)));
        std.debug.print("Body: {s}\n", .{buf.items});

        try multi.removeHandle(easy_handle);

        c.curl_easy_cleanup(easy_handle);
        // Note: there is also `curl_easy_reset` if you want to reuse the handle
        // for another request
    }
}
