const std = @import("std");
const println = @import("util.zig").println;
const mem = std.mem;
const Allocator = mem.Allocator;
const curl = @import("curl");
const Easy = curl.Easy;

const LOCAL_SERVER_ADDR = "http://localhost:8182";

fn get(allocator: Allocator, easy: Easy) !void {
    try easy.setVerbose(true);
    const resp = try easy.get("https://httpbin.org/anything");
    defer resp.deinit();

    const body = resp.body.?.items;
    std.debug.print("Status code: {d}\nBody: {s}\n", .{
        resp.status_code,
        body,
    });

    const Response = struct {
        headers: struct {
            Host: []const u8,
        },
        method: []const u8,
    };
    const parsed = try std.json.parseFromSlice(Response, allocator, body, .{
        .ignore_unknown_fields = true,
    });
    defer parsed.deinit();

    try std.testing.expectEqualDeep(parsed.value, Response{
        .headers = .{ .Host = "httpbin.org" },
        .method = "GET",
    });
}

fn post(allocator: Allocator, easy: Easy) !void {
    const payload =
        \\{"name": "John", "age": 15}
    ;
    try easy.setVerbose(false);
    const resp = try easy.post("https://httpbin.org/anything", "application/json", payload);
    defer resp.deinit();

    std.debug.print("Status code: {d}\nBody: {s}\n", .{
        resp.status_code,
        resp.body.?.items,
    });

    const Response = struct {
        headers: struct {
            @"Content-Type": []const u8,
        },
        json: struct {
            name: []const u8,
            age: u32,
        },
        method: []const u8,
    };
    const parsed = try std.json.parseFromSlice(Response, allocator, resp.body.?.items, .{ .ignore_unknown_fields = true });
    defer parsed.deinit();

    try std.testing.expectEqualDeep(parsed.value, Response{
        .headers = .{ .@"Content-Type" = "application/json" },
        .json = .{ .name = "John", .age = 15 },
        .method = "POST",
    });
}

fn upload(allocator: Allocator, easy: Easy) !void {
    const path = "LICENSE";
    const resp = try easy.upload(LOCAL_SERVER_ADDR ++ "/anything", path);
    const Response = struct {
        method: []const u8,
        body_len: usize,
    };
    const parsed = try std.json.parseFromSlice(Response, allocator, resp.body.?.items, .{ .ignore_unknown_fields = true });
    defer parsed.deinit();

    try std.testing.expectEqualDeep(parsed.value, Response{
        .body_len = 1086,
        .method = "PUT",
    });

    std.debug.print("Status code: {d}\nBody: {s}\n", .{
        resp.status_code,
        resp.body.?.items,
    });
}

pub fn main() !void {
    const allocator = std.heap.page_allocator;

    const ca_bundle = try curl.allocCABundle(allocator);
    defer ca_bundle.deinit();
    const easy = try Easy.init(allocator, .{
        .ca_bundle = ca_bundle,
    });
    defer easy.deinit();

    println("GET demo");
    try get(allocator, easy);

    println("POST demo");
    easy.reset();
    try post(allocator, easy);

    println("Upload demo");
    easy.reset();
    try upload(allocator, easy);
}
