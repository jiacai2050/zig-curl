const std = @import("std");
const host = "127.0.0.1";
const port = 8182;

pub fn main() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer if (gpa.deinit() == .leak) @panic("Memory leaked!");
    const allocator = gpa.allocator();

    const addr = try std.net.Address.resolveIp(host, port);
    var server = try addr.listen(.{ .reuse_address = true });
    defer server.deinit();
    std.log.info("Listening on {}", .{server.listen_address});

    var read_buffer: [2048]u8 = undefined;
    while (true) new_connection: {
        const conn = try server.accept();
        defer conn.stream.close();

        var http_server = std.http.Server.init(conn, &read_buffer);
        while (http_server.state == .ready) {
            var request = http_server.receiveHead() catch |err| {
                if (err != error.HttpConnectionClosing and err != error.HttpRequestTruncated) {
                    std.log.err("Failed to receive http request: {s}", .{@errorName(err)});
                }
                break :new_connection;
            };

            handleRequest(allocator, &request) catch {
                std.log.err("Failed to handle request: {?}", .{@errorReturnTrace()});
                break :new_connection;
            };
        }
    }
}

fn handleRequest(allocator: std.mem.Allocator, request: *std.http.Server.Request) !void {
    const uri = try std.Uri.parseAfterScheme(&.{}, request.head.target);
    if (!std.mem.eql(u8, uri.path.percent_encoded, "/anything")) {
        try request.respond(&.{}, .{ .status = .not_found });
        return;
    }

    var arena = std.heap.ArenaAllocator.init(allocator);
    defer arena.deinit();
    const arena_allocator = arena.allocator();

    const body = try (try request.reader()).readAllAlloc(arena_allocator, 8192);

    var headers = std.json.ArrayHashMap([]const u8){};
    var header_iter = request.iterateHeaders();
    while (header_iter.next()) |header| {
        try headers.map.put(arena_allocator, header.name, header.value);
    }

    var send_buffer: [2048]u8 = undefined;
    var response = request.respondStreaming(.{
        .send_buffer = &send_buffer,
        .respond_options = .{ .extra_headers = &.{
            .{ .name = "content-type", .value = "application/json" },
        } },
    });
    try std.json.stringify(
        .{
            .method = request.head.method,
            .path = uri.path.percent_encoded,
            .body = body,
            .body_len = body.len,
            .headers = headers,
        },
        .{
            .whitespace = .indent_2,
        },
        response.writer(),
    );
    try response.end();
}
