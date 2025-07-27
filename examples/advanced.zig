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
        var h: Easy.Headers = .{};
        errdefer h.deinit();
        try h.add("content-type: application/json");
        try h.add(std.fmt.comptimePrint("user-agent: {s}", .{UA}));
        try h.add("Authorization: Basic YWxhZGRpbjpvcGVuc2VzYW1l");
        break :blk h;
    };
    defer headers.deinit();

    try easy.setUrl("https://httpbin.org/anything/zig-curl");
    try easy.setHeaders(headers);
    try easy.setMethod(.PUT);
    try easy.setVerbose(true);
    try easy.setPostFields(body);

    var writeContext = curl.ResizableWriteContext.init(allocator);
    defer writeContext.deinit();
    try easy.setWriteContext(&writeContext, curl.ResizableWriteContext.write);

    const resp = try easy.perform();
    std.debug.print("Status code: {d}\nBody: {s}\n", .{
        resp.status_code,
        writeContext.asSlice(),
    });

    const parsed = try std.json.parseFromSlice(
        Response,
        allocator,
        writeContext.asSlice(),
        .{ .ignore_unknown_fields = true },
    );
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

fn postMultiPart(allocator: Allocator, easy: Easy) !void {
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

    var writeContext = curl.ResizableWriteContext.init(allocator);
    defer writeContext.deinit();
    try easy.setWriteContext(&writeContext, curl.ResizableWriteContext.write);

    const resp = try easy.perform();
    std.debug.print("code: {d}, resp:{s}\n", .{ resp.status_code, writeContext.asSlice() });
}

pub fn main() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer if (gpa.deinit() != .ok) @panic("leak");
    const allocator = gpa.allocator();

    const ca_bundle = try curl.allocCABundle(allocator);
    defer ca_bundle.deinit();
    const easy = try Easy.init(.{ .ca_bundle = ca_bundle });
    defer easy.deinit();

    println("PUT with custom header demo");
    try putWithCustomHeader(allocator, easy);
    try postMultiPart(allocator, easy);
}
