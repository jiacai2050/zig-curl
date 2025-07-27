const std = @import("std");
const println = @import("util.zig").println;
const mem = std.mem;
const Allocator = mem.Allocator;
const curl = @import("curl");
const Easy = curl.Easy;

const LOCAL_SERVER_ADDR = "http://localhost:8182";

fn get(easy: Easy) !void {
    {
        println("GET without write context");
        const resp = try easy.fetch("https://httpbin.org/anything", .{}, {});

        std.debug.print("Status code: {d}\n", .{resp.status_code});
    }

    {
        println("GET with fixed buffer");
        var buffer: [1024]u8 = undefined;
        var writeContext = curl.FixedWriteContext.init(&buffer);
        const resp = try easy.fetch("https://httpbin.org/anything", .{}, &writeContext);
        std.debug.print("Status code: {d}\nBody: {s}\n", .{
            resp.status_code,
            writeContext.asSlice(),
        });
    }
}

fn post(allocator: Allocator, easy: Easy) !void {
    const payload =
        \\{"name": "John", "age": 15}
    ;
    var writeContext = curl.ResizableWriteContext.init(allocator);
    defer writeContext.deinit();
    const resp = try easy.fetch(
        "https://httpbin.org/anything",
        .{
            .method = .POST,
            .body = payload,
            .headers = &.{
                "Content-Type: application/json",
            },
        },
        &writeContext,
    );

    std.debug.print("Status code: {d}\nBody: {s}\n", .{
        resp.status_code,
        writeContext.asSlice(),
    });
}

fn upload(allocator: Allocator, easy: Easy) !void {
    const path = "LICENSE";
    var writeContext = curl.ResizableWriteContext.init(allocator);
    defer writeContext.deinit();

    const resp = try easy.upload(LOCAL_SERVER_ADDR ++ "/anything", path, &writeContext);

    std.debug.print("Status code: {d}\nBody: {s}\n", .{
        resp.status_code,
        writeContext.asSlice(),
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

    try easy.setVerbose(false);
    println("GET demo");
    try get(easy);

    println("POST demo");
    easy.reset();
    try post(allocator, easy);

    println("Upload demo");
    easy.reset();
    try upload(allocator, easy);
}
