const std = @import("std");
const println = @import("util.zig").println;
const mem = std.mem;
const Allocator = mem.Allocator;
const curl = @import("curl");
const Easy = curl.Easy;

const UA = "Mozilla/5.0 (X11; Linux x86_64; rv:109.0) Gecko/20100101 Firefox/115.0";

pub fn main(init: std.process.Init) !void {
    var gpa = std.heap.DebugAllocator(.{}){};
    defer if (gpa.deinit() != .ok) @panic("leak");
    const allocator = gpa.allocator();

    var ca_bundle = try curl.allocCABundle(allocator, init.io);
    defer ca_bundle.deinit(allocator);

    var easy = try Easy.init(.{
        .ca_bundle = ca_bundle,
    });
    defer easy.deinit();

    println("PUT with custom header demo");
    putWithCustomHeader(allocator, &easy) catch |err| {
        if (easy.diagnostics.error_code) |error_code| {
            switch (error_code) {
                .code => |curl_code| {
                    std.log.err(
                        "putWithCustomHeader encountered a curl error! error code: {}",
                        .{curl_code},
                    );
                },
                .m_code => |curl_multi_code| {
                    std.log.err(
                        "putWithCustomHeader encountered a curl multi error! error code: {}",
                        .{curl_multi_code},
                    );
                },
            }
        }
        return err;
    };
    postMultiPart(allocator, &easy) catch |err| {
        if (easy.diagnostics.error_code) |error_code| {
            switch (error_code) {
                .code => |curl_code| {
                    std.log.err(
                        "postMultipart encountered a curl error! error code: {}",
                        .{curl_code},
                    );
                },
                .m_code => |curl_multi_code| {
                    std.log.err(
                        "postMultipart encountered a curl multi error! error code: {}",
                        .{curl_multi_code},
                    );
                },
            }
        }
        return err;
    };
}

const Response = struct {
    headers: struct {
        @"user-agent": []const u8,
        authorization: []const u8,
    },
    json: struct {
        name: []const u8,
        age: usize,
    },
    method: []const u8,
    url: []const u8,
};

fn putWithCustomHeader(allocator: Allocator, easy: *Easy) !void {
    const body =
        \\ {"name": "John", "age": 15}
    ;

    const headers = blk: {
        var headers_builder: Easy.Headers = .{};
        errdefer headers_builder.deinit();
        try headers_builder.add("content-type: application/json");
        try headers_builder.add(std.fmt.comptimePrint("user-agent: {s}", .{UA}));
        try headers_builder.add("Authorization: Basic YWxhZGRpbjpvcGVuc2VzYW1l");
        break :blk headers_builder;
    };
    defer headers.deinit();

    try easy.setUrl("https://edgebin.liujiacai.net/anything/zig-curl");
    try easy.setHeaders(headers);
    try easy.setMethod(.PUT);
    try easy.setVerbose(true);
    try easy.setPostFields(body);

    var writer = std.Io.Writer.Allocating.init(allocator);
    defer writer.deinit();
    try easy.setWriter(&writer.writer);

    const response = try easy.perform();
    std.debug.print("Status code: {d}\nBody: {s}\n", .{
        response.status_code,
        writer.writer.buffered(),
    });

    const parsed = try std.json.parseFromSlice(
        Response,
        allocator,
        writer.writer.buffered(),
        .{ .ignore_unknown_fields = true },
    );
    defer parsed.deinit();

    try std.testing.expectEqualDeep(
        parsed.value,
        Response{
            .headers = .{
                .@"user-agent" = UA,
                .authorization = "Basic YWxhZGRpbjpvcGVuc2VzYW1l",
            },
            .json = .{
                .name = "John",
                .age = 15,
            },
            .method = "PUT",
            .url = "https://edgebin.liujiacai.net/anything/zig-curl",
        },
    );

    // Get response header `date`.
    const date_header = response.getHeader("date") catch |err| {
        std.debug.print("Get header error: {any}\n", .{err});
        return;
    };
    if (date_header) |header| {
        std.debug.print("date header: {s}\n", .{header.get()});
    } else {
        std.debug.print("date header not found\n", .{});
    }
}

fn postMultiPart(allocator: Allocator, easy: *Easy) !void {
    // Reset old options, e.g. headers.
    easy.reset();

    const multi_part = try easy.createMultiPart();
    try multi_part.addPart("foo", .{ .data = "hello foo" });
    try multi_part.addPart("bar", .{ .data = "hello bar" });
    try multi_part.addPart("readme", .{ .file = "examples/test.txt" });
    defer multi_part.deinit();

    try easy.setUrl("https://edgebin.liujiacai.net/anything/mp");
    try easy.setMethod(.PUT);
    try easy.setMultiPart(multi_part);
    try easy.setVerbose(true);

    var writer = std.Io.Writer.Allocating.init(allocator);
    defer writer.deinit();

    try easy.setWriter(&writer.writer);

    const response = try easy.perform();
    std.debug.print("code: {d}, response:{s}\n", .{
        response.status_code,
        writer.writer.buffered(),
    });
}
