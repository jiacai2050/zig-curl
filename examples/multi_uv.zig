//! Demonstrates using `MultiUv` for high-performance concurrent HTTP transfers
//! driven by libuv's event loop instead of a blocking poll.
//!
//! Build and run:
//!   zig build run-multi-uv -Dlibuv=true
const std = @import("std");
const println = @import("util.zig").println;
const curl = @import("curl");
const c_uv = @cImport({
    @cInclude("uv.h");
});

const MultiUv = curl.MultiUv;
const Easy = curl.Easy;
const c = curl.libcurl;
const Writer = std.io.Writer;

/// Called by `MultiUv` for every completed transfer.
fn onComplete(context: ?*anyopaque, handle: *c.CURL, result: c.CURLcode) void {
    _ = context;

    if (result != c.CURLE_OK) {
        std.debug.print("Transfer failed: CURLcode={d}\n", .{result});
        return;
    }

    var status_code: c_long = 0;
    _ = c.curl_easy_getinfo(handle, c.CURLINFO_RESPONSE_CODE, &status_code);

    // Retrieve the Writer pointer stored via CURLOPT_PRIVATE.
    var private_data: ?*anyopaque = null;
    _ = c.curl_easy_getinfo(handle, c.CURLINFO_PRIVATE, &private_data);
    const writer: *Writer = @ptrCast(@alignCast(private_data.?));

    std.debug.print("Response Code: {d}, body length: {d}\n", .{
        status_code,
        writer.buffered().len,
    });
}

pub fn main() !void {
    var gpa = std.heap.DebugAllocator(.{}){};
    defer if (gpa.deinit() != .ok) @panic("leak");
    const allocator = gpa.allocator();

    const loop = c_uv.uv_default_loop();

    var multi = try MultiUv.create(allocator, loop, onComplete, null);
    defer multi.destroy();

    var wtr1 = std.Io.Writer.Allocating.init(allocator);
    defer wtr1.deinit();
    var wtr2 = std.Io.Writer.Allocating.init(allocator);
    defer wtr2.deinit();
    var wtr3 = std.Io.Writer.Allocating.init(allocator);
    defer wtr3.deinit();

    var easy1 = try Easy.init(.{});
    defer easy1.deinit();
    try easy1.setUrl("http://edgebin.liujiacai.net/headers");
    try easy1.setWriter(&wtr1.writer);
    try easy1.setPrivate(&wtr1.writer);

    var easy2 = try Easy.init(.{});
    defer easy2.deinit();
    try easy2.setUrl("http://edgebin.liujiacai.net/ip");
    try easy2.setWriter(&wtr2.writer);
    try easy2.setPrivate(&wtr2.writer);

    var easy3 = try Easy.init(.{});
    defer easy3.deinit();
    try easy3.setUrl("http://edgebin.liujiacai.net/anything");
    try easy3.setWriter(&wtr3.writer);
    try easy3.setPrivate(&wtr3.writer);

    try multi.addHandle(&easy1);
    try multi.addHandle(&easy2);
    try multi.addHandle(&easy3);

    println("Starting libuv event loop for concurrent transfers...");
    _ = c_uv.uv_run(loop, c_uv.UV_RUN_DEFAULT);
    println("Event loop finished — all transfers complete.");
}
