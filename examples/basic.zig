const std = @import("std");
const println = @import("util.zig").println;
const mem = std.mem;
const Allocator = mem.Allocator;
const curl = @import("curl");
const Easy = curl.Easy;

fn get(allocator: Allocator, easy: Easy) !void {
    const resp = try easy.get("https://httpbin.org/anything");
    defer resp.deinit();

    std.debug.print("Status code: {d}\nBody: {s}\n", .{
        resp.status_code,
        resp.body.items,
    });

    const Response = struct {
        headers: struct {
            Host: []const u8,
        },
        method: []const u8,
    };
    const parsed = try std.json.parseFromSlice(Response, allocator, resp.body.items, .{
        .ignore_unknown_fields = true,
    });
    defer parsed.deinit();

    try std.testing.expectEqualDeep(parsed.value, Response{
        .headers = .{ .Host = "httpbin.org" },
        .method = "GET",
    });
}

fn post(allocator: Allocator, easy: *Easy) !void {
    const payload =
        \\{"name": "John", "age": 15}
    ;
    const resp = try easy.post("https://httpbin.org/anything", "application/json", payload);
    defer resp.deinit();

    std.debug.print("Status code: {d}\nBody: {s}\n", .{
        resp.status_code,
        resp.body.items,
    });

    const Response = struct {
        headers: struct {
            @"User-Agent": []const u8,
            @"Content-Type": []const u8,
        },
        json: struct {
            name: []const u8,
            age: u32,
        },
        method: []const u8,
    };
    const parsed = try std.json.parseFromSlice(Response, allocator, resp.body.items, .{ .ignore_unknown_fields = true });
    defer parsed.deinit();

    try std.testing.expectEqualDeep(parsed.value, Response{
        .headers = .{ .@"User-Agent" = "zig-curl/0.1.0", .@"Content-Type" = "application/json" },
        .json = .{ .name = "John", .age = 15 },
        .method = "POST",
    });
}

pub fn main() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer if (gpa.deinit() != .ok) @panic("leak");
    const allocator = gpa.allocator();

    var easy = try Easy.init(allocator, .{});
    defer easy.deinit();

    println("GET demo");
    try get(allocator, easy);

    println("POST demo");
    try post(allocator, &easy);
}
