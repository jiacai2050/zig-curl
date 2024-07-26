const std = @import("std");
const println = @import("util.zig").println;
const mem = std.mem;
const Allocator = mem.Allocator;
const curl = @import("curl");
const Easy = curl.Easy;

const UA = "Mozilla/5.0 (X11; Linux x86_64; rv:109.0) Gecko/20100101 Firefox/115.0";

const Response = struct {
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

fn putWithCustomHeader(allocator: Allocator, easy: Easy) !void {
    const body =
        \\ {"name": "John", "age": 15}
    ;

    const headers = blk: {
        var h = try easy.createHeaders();
        errdefer h.deinit();
        try h.add("content-type", "application/json");
        try h.add("user-agent", UA);
        try h.add("Authorization", "Basic YWxhZGRpbjpvcGVuc2VzYW1l");
        break :blk h;
    };
    defer headers.deinit();

    try easy.setUrl("https://httpbin.org/anything/zig-curl");
    try easy.setHeaders(headers);
    try easy.setMethod(.PUT);
    try easy.setVerbose(true);
    try easy.setPostFields(body);
    var buf = curl.Buffer.init(allocator);
    try easy.setWritedata(&buf);
    try easy.setWritefunction(curl.bufferWriteCallback);

    var resp = try easy.perform();
    resp.body = buf;
    defer resp.deinit();

    std.debug.print("Status code: {d}\nBody: {s}\n", .{
        resp.status_code,
        resp.body.?.items,
    });

    const parsed = try std.json.parseFromSlice(Response, allocator, resp.body.?.items, .{
        .ignore_unknown_fields = true,
    });
    defer parsed.deinit();

    try std.testing.expectEqualDeep(
        parsed.value,
        Response{
            .headers = .{
                .@"User-Agent" = UA,
                .Authorization = "Basic YWxhZGRpbjpvcGVuc2VzYW1l",
            },
            .json = .{
                .name = "John",
                .age = 15,
            },
            .method = "PUT",
            .url = "https://httpbin.org/anything/zig-curl",
        },
    );

    // Get response header `date`.
    const date_header = resp.getHeader("date") catch |err| {
        std.debug.print("Get header error: {any}\n", .{err});
        return;
    };
    if (date_header) |h| {
        std.debug.print("date header: {s}\n", .{h.get()});
    } else {
        std.debug.print("date header not found\n", .{});
    }
}

fn postMutliPart(easy: Easy) !void {
    // Reset old options, e.g. headers.
    easy.reset();

    const multi_part = try easy.createMultiPart();
    try multi_part.addPart("foo", .{ .data = "hello foo" });
    try multi_part.addPart("bar", .{ .data = "hello bar" });
    try multi_part.addPart("build.zig", .{ .file = "build.zig" });
    try multi_part.addPart("readme", .{ .file = "README.org" });
    defer multi_part.deinit();

    try easy.setUrl("https://httpbin.org/anything/mp");
    try easy.setMethod(.PUT);
    try easy.setMultiPart(multi_part);
    try easy.setVerbose(true);
    var buf = curl.Buffer.init(easy.allocator);
    try easy.setWritedata(&buf);
    try easy.setWritefunction(curl.bufferWriteCallback);

    var resp = try easy.perform();
    resp.body = buf;
    defer resp.deinit();

    std.debug.print("resp:{s}\n", .{resp.body.?.items});
}

fn iterateHeaders(easy: Easy) !void {
    // Reset old options, e.g. headers.
    easy.reset();

    const resp = try easy.get("https://httpbin.org/response-headers?X-Foo=1&X-Foo=2&X-Foo=3");
    defer resp.deinit();

    std.debug.print("Iterating all headers...\n", .{});
    {
        var iter = try resp.iterateHeaders(.{});
        while (try iter.next()) |header| {
            std.debug.print("  {s}: {s}\n", .{ header.name, header.get() });
        }
    }

    // Iterating X-Foo only
    {
        var iter = try resp.iterateHeaders(.{ .name = "X-Foo" });
        const expected_values = .{ "1", "2", "3" };
        inline for (expected_values) |expected| {
            const header = try iter.next() orelse unreachable;
            try std.testing.expectEqualStrings(header.get(), expected);
        }
        try std.testing.expect((try iter.next()) == null);
    }
}

fn iterateRedirectedHeaders(easy: Easy) !void {
    // Reset old options, e.g. headers.
    easy.reset();

    try easy.setFollowLocation(true);
    const resp = try easy.get("https://httpbin.org/redirect/1");
    defer resp.deinit();

    const redirects = try resp.getRedirectCount();
    try std.testing.expectEqual(redirects, 1);

    for (0..redirects + 1) |i| {
        std.debug.print("Request #{} headers:\n", .{i});
        var iter = try resp.iterateHeaders(.{ .request = i });
        while (try iter.next()) |header| {
            std.debug.print("  {s}: {s}\n", .{ header.name, header.get() });
        }
    }
}

pub fn main() !void {
    const allocator = std.heap.page_allocator;

    const ca_bundle = try curl.allocCABundle(allocator);
    defer ca_bundle.deinit();
    const easy = try Easy.init(allocator, .{
        .ca_bundle = ca_bundle,
    });
    defer easy.deinit();

    curl.printLibcurlVersion();

    println("PUT with custom header demo");
    try putWithCustomHeader(allocator, easy);
    try postMutliPart(easy);

    println("Iterate headers demo");
    iterateHeaders(easy) catch |err| switch (err) {
        error.NoCurlHeaderSupport => std.debug.print("No header support, skipping...\n", .{}),
        else => return err,
    };

    println("Redirected headers demo");
    iterateRedirectedHeaders(easy) catch |err| switch (err) {
        error.NoCurlHeaderSupport => std.debug.print("No header support, skipping...\n", .{}),
        else => return err,
    };
}
