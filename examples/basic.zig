const std = @import("std");
const println = @import("util.zig").println;
const mem = std.mem;
const Allocator = mem.Allocator;
const curl = @import("curl");
const Easy = curl.Easy;

const LOCAL_SERVER_ADDR = "http://localhost:8182";

fn get(allocator: Allocator, easy: Easy) !void {
    {
        println("GET with allocator");
        const resp = try easy.fetchAlloc("https://httpbin.org/anything", allocator, .{});
        defer resp.deinit();

        const body = resp.body.?.slice();
        std.debug.print("Status code: {d}\nBody: {s}\n", .{
            resp.status_code,
            body,
        });
    }

    {
        println("GET with fixed buffer");
        var buffer: [1024]u8 = undefined;
        const resp = try easy.fetch("https://httpbin.org/anything", &buffer, .{});
        defer resp.deinit();
        const body = resp.body.?.slice();
        std.debug.print("Status code: {d}\nBody: {s}\n", .{
            resp.status_code,
            body,
        });
    }

    {
        println("GET with file");
        var file = try std.fs.cwd().createFile("resp.txt", .{ .read = true, .truncate = true });

        defer file.close();
        const resp = try easy.fetchFile("https://httpbin.org/anything", &file, .{});
        defer resp.deinit();

        try file.seekTo(0);
        const body = try file.readToEndAlloc(allocator, (try file.stat()).size);
        defer allocator.free(body);
        std.debug.print("Status code: {d}\nBody: {s}\n", .{
            resp.status_code,
            body,
        });

        try std.fs.cwd().deleteFile("resp.txt");
    }
}

fn post(allocator: Allocator, easy: Easy) !void {
    const payload =
        \\{"name": "John", "age": 15}
    ;
    const resp = try easy.fetchAlloc(
        "https://httpbin.org/anything",
        allocator,
        .{
            .method = .POST,
            .body = payload,
            .headers = &.{
                "Content-Type: application/json",
            },
        },
    );
    defer resp.deinit();

    std.debug.print("Status code: {d}\nBody: {s}\n", .{
        resp.status_code,
        resp.body.?.slice(),
    });
}

fn upload(allocator: Allocator, easy: Easy) !void {
    const path = "LICENSE";
    const resp = try easy.uploadAlloc(LOCAL_SERVER_ADDR ++ "/anything", path, allocator);
    defer resp.deinit();

    std.debug.print("Status code: {d}\nBody: {s}\n", .{
        resp.status_code,
        resp.body.?.slice(),
    });
}

pub fn main() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer if (gpa.deinit() != .ok) @panic("leak");
    const allocator = gpa.allocator();

    const ca_bundle = try curl.allocCABundle(allocator);
    defer ca_bundle.deinit();
    const easy = try Easy.init(.{
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
