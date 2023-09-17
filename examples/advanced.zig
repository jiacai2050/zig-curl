const std = @import("std");
const mem = std.mem;
const Allocator = mem.Allocator;
const curl = @import("curl");
const Easy = curl.Easy;

fn put_with_custom_header(allocator: Allocator, easy: Easy) !void {
    var payload = std.io.fixedBufferStream(
        \\{"name": "John", "age": 15}
    );

    const header = blk: {
        var h = curl.RequestHeader.init(allocator);
        errdefer h.deinit();
        try h.add(curl.HEADER_CONTENT_TYPE, "application/json");
        try h.add("User-Agent", "zig-curl/0.1.0");
        break :blk h;
    };
    var req = curl.request(
        "http://httpbin.org/anything",
        payload.reader(),
    );
    req.method = .PUT;
    req.header = header;
    defer req.deinit();

    const resp = try easy.do(req);
    defer resp.deinit();

    std.debug.print("Status code: {d}\nBody: {s}\n", .{
        resp.status_code,
        resp.body.items,
    });

    if (!curl.has_curl_header_support()) {
        return;
    }
    // Get response header `date`.
    const date_header = try resp.get_header("date");
    if (date_header) |h| {
        std.debug.print("date header: {s}\n", .{h.get()});
    } else {
        std.debug.print("date header not found\n", .{});
    }
}

pub fn main() !void {
    var arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    const easy = try Easy.init(allocator);
    defer easy.deinit();

    curl.print_libcurl_version();

    const sep = "-" ** 20;
    std.debug.print("{s}PUT with custom header demo{s}\n", .{ sep, sep });
    try put_with_custom_header(allocator, easy);
}
