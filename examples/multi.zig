const std = @import("std");
const println = @import("util.zig").println;
const mem = std.mem;
const Allocator = mem.Allocator;
const curl = @import("curl");
const Easy = curl.Easy;
const Multi = curl.Multi;
const c = curl.libcurl;
const checkCode = curl.checkCode;
const Writer = std.Io.Writer;

fn newEasy(writer: *Writer, url: [:0]const u8) !Easy {
    var easy = try Easy.init(.{});
    try easy.setUrl(url);
    try easy.setWriter(writer);
    // CURLOPT_PRIVATE allows us to store a pointer to the ctx in the easy handle
    // so we can retrieve it later in the callback.
    try easy.setPrivate(writer);

    return easy;
}

pub fn main(init: std.process.Init) !void {
    const allocator = init.gpa;

    var multi = try Multi.init();
    defer multi.deinit() catch |e| {
        std.debug.print("multi handle deinit failed, err:{any}\n", .{e});
        if (multi.diagnostics.getMessage()) |message| {
            std.debug.print("Diagnostics: {s}\n", .{message});
        }
    };

    var headers_writer = std.Io.Writer.Allocating.init(allocator);
    defer headers_writer.deinit();
    var ip_writer = std.Io.Writer.Allocating.init(allocator);
    defer ip_writer.deinit();

    var headers_easy = try newEasy(&headers_writer.writer, "http://edgebin.liujiacai.net/headers");
    defer headers_easy.deinit();
    var ip_easy = try newEasy(&ip_writer.writer, "http://edgebin.liujiacai.net/ip");
    defer ip_easy.deinit();

    try multi.addHandle(&headers_easy);
    try multi.addHandle(&ip_easy);

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
        try checkCode(info.msg.data.result, &multi.diagnostics);

        // Read the HTTP status code
        var status_code: c_long = 0;
        try checkCode(c.curl_easy_getinfo(easy_handle, c.CURLINFO_RESPONSE_CODE, &status_code), &multi.diagnostics);
        std.debug.print("Response Code: {any}\n", .{status_code});

        // Get the private data (buffer) associated with this handle
        var private_data: ?*anyopaque = null;
        try checkCode(c.curl_easy_getinfo(easy_handle, c.CURLINFO_PRIVATE, &private_data), &multi.diagnostics);
        const writer: *Writer = @ptrCast(@alignCast(private_data.?));

        std.debug.print("Response body: {s}\n", .{writer.buffered()});
    }
}
