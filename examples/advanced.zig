const std = @import("std");
const println = @import("util.zig").println;
const mem = std.mem;
const Allocator = mem.Allocator;
const curl = @import("curl");
const Easy = curl.Easy;

const UA = "Mozilla/5.0 (X11; Linux x86_64; rv:109.0) Gecko/20100101 Firefox/115.0";

const Resposne = struct {
    headers: struct {
        @"User-Agent": []const u8,
        Authorization: []const u8,
    },
    json: struct {
        name: []const u8,
        age: usize,
    },
    method: []const u8,
    url: []const u8,
};

fn put_with_custom_header(allocator: Allocator, easy: Easy) !void {
    var stream = std.io.fixedBufferStream(
        \\ {"name": "John", "age": 15}
    );
    var body = stream.reader();

    const header = blk: {
        var h = curl.RequestHeader.init(allocator);
        errdefer h.deinit();
        try h.add(curl.HEADER_CONTENT_TYPE, "application/json");
        try h.add("user-agent", UA);
        try h.add("Authorization", "Basic YWxhZGRpbjpvcGVuc2VzYW1l");
        break :blk h;
    };
    var req = curl.Request(@TypeOf(body)).init("http://httpbin.org/anything/zig-curl", body, .{
        .method = .PUT,
        .header = header,
        .verbose = true,
    });
    defer req.deinit();

    const resp = try easy.do(req);
    defer resp.deinit();

    std.debug.print("Status code: {d}\nBody: {s}\n", .{
        resp.status_code,
        resp.body.items,
    });

    const parsed = try std.json.parseFromSlice(Resposne, allocator, resp.body.items, .{
        .ignore_unknown_fields = true,
    });
    defer parsed.deinit();

    try std.testing.expectEqualDeep(
        parsed.value,
        .{
            .headers = .{
                .@"User-Agent" = UA,
                .Authorization = "Basic YWxhZGRpbjpvcGVuc2VzYW1l",
            },
            .json = .{
                .name = "John",
                .age = 15,
            },
            .method = "PUT",
            .url = "http://httpbin.org/anything/zig-curl",
        },
    );

    if (!curl.has_parse_header_support()) {
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

fn post_mutli_part(easy: Easy) !void {
    const multi_part = try easy.add_multi_part();
    try multi_part.add_part("foo", .{ .data = "hello foo" });
    try multi_part.add_part("bar", .{ .data = "hello bar" });
    try multi_part.add_part("build.zig", .{ .file = "build.zig" });
    try multi_part.add_part("readme", .{ .file = "README.org" });

    var req = curl.Request(void).init("http://httpbin.org/anything/mp", {}, .{
        .method = .PUT,
        .multi_part = multi_part,
        .verbose = true,
    });
    defer req.deinit();

    const resp = try easy.do(req);
    defer resp.deinit();

    std.debug.print("resp:{s}\n", .{resp.body.items});
}

pub fn main() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer if (gpa.deinit() != .ok) @panic("leak");
    var allocator = gpa.allocator();

    const easy = try Easy.init(allocator);
    defer easy.deinit();

    curl.print_libcurl_version();

    println("PUT with custom header demo");
    try put_with_custom_header(allocator, easy);
    try post_mutli_part(easy);
}
