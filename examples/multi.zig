const std = @import("std");
const println = @import("util.zig").println;
const mem = std.mem;
const Allocator = mem.Allocator;
const curl = @import("curl");
const Easy = curl.Easy;
const Multi = curl.Multi;
const c = curl.libcurl;
const checkCode = curl.checkCode;
const AnyWriter = std.io.AnyWriter;

fn newEasy(writer: *curl.ResizableResponseWriter, any_writer: *const AnyWriter, url: [:0]const u8) !Easy {
    const easy = try Easy.init(.{});
    try easy.setUrl(url);
    try easy.setAnyWriter(any_writer);
    // CURLOPT_PRIVATE allows us to store a pointer to the ctx in the easy handle
    // so we can retrieve it later in the callback.
    try easy.setPrivate(writer);

    return easy;
}

pub fn main() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer if (gpa.deinit() != .ok) @panic("leak");
    const allocator = gpa.allocator();

    const multi = try Multi.init();
    defer multi.deinit();

    var wtr1 = curl.ResizableResponseWriter.init(allocator);
    defer wtr1.deinit();
    const any_writer1: AnyWriter = wtr1.asAny();
    var wtr2 = curl.ResizableResponseWriter.init(allocator);
    defer wtr2.deinit();
    const any_writer2: AnyWriter = wtr2.asAny();

    try multi.addHandle(try newEasy(&wtr1, &any_writer1, "http://httpbin.org/headers"));
    try multi.addHandle(try newEasy(&wtr2, &any_writer2, "http://httpbin.org/ip"));

    var keep_running = true;
    while (keep_running) {
        const still_running = try multi.perform();
        keep_running = still_running > 0;
        std.debug.print("{d} pending requests...\n", .{still_running});

        const num_fds = try multi.poll(null, 300);
        std.debug.print("{d} requests had activity...\n", .{num_fds});

        const info = multi.readInfo() catch |e| switch (e) {
            // no new data to read on this iteration
            error.InfoReadExhausted => continue,
        };

        // If we have `info` then one of the requests completed
        const easy_handle = info.msg.easy_handle.?;
        defer {
            multi.removeHandle(easy_handle) catch |e| {
                std.debug.print("{any}", .{e});
            };
            c.curl_easy_cleanup(easy_handle);
        }

        // check that the request was successful
        try checkCode(info.msg.data.result);

        // Read the HTTP status code
        var status_code: c_long = 0;
        try checkCode(c.curl_easy_getinfo(easy_handle, c.CURLINFO_RESPONSE_CODE, &status_code));
        std.debug.print("Response Code: {any}\n", .{status_code});

        // Get the private data (buffer) associated with this handle
        var private_data: ?*anyopaque = null;
        try checkCode(c.curl_easy_getinfo(easy_handle, c.CURLINFO_PRIVATE, &private_data));
        const writer: *curl.ResizableResponseWriter = @ptrCast(@alignCast(private_data.?));

        std.debug.print("Response body: {s}\n", .{writer.asSlice()});
    }
}
