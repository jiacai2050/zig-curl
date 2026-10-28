//! ![zig curl logo](https://raw.githubusercontent.com/jiacai2050/zig-curl/main/docs/logo.svg)
//!
//! [Zig-curl](https://github.com/jiacai2050/zig-curl) is a safe, high-performance, and idiomatic
//! Zig binding for [libcurl](https://curl.se/libcurl/).
//!
//! The library provides **two distinct layers of APIs** tailored to different concurrency,
//! ergonomics, and control requirements:
//!
//! ---
//!
//! ### 1. High-Level Asynchronous API (`Client` & `RequestBuilder`)
//!
//! This is the **recommended API for modern, concurrent applications**.
//! It seamlessly integrates libcurl's multi-handle engine with Zig's `std.Io` cooperative fiber runtime:
//!
//! - **Non-blocking Concurrency**: Calling `request.send(io)` cooperatively suspends the caller
//!   fiber without blocking OS threads, maximizing throughput in high-concurrency environments.
//! - **Low-Contention Resource Pooling**: Automatically maintains a thread-safe pool of `Easy`
//!   handles (`HandlePool`) and transparently shares DNS, connection pools, and TLS sessions via `CURLSH`.
//! - **Zero-CPU Idle Reactor**: The dedicated background driver thread auto-adapts its polling timeout
//!   and sleeps during idle periods, responding instantly to new requests via `curl_multi_wakeup`.
//! - **Rich Ergonomics**: Fluent builder pattern, structured headers, custom timeouts,
//!   streaming response bodies (`sendStreaming(io)` via standard `std.Io.Reader`), and strongly-typed JSON deserialization.
//!
//! **Example Usage (Buffered & Streaming)**:
//! ```zig
//! const std = @import("std");
//! const curl = @import("curl");
//!
//! pub fn fetchUser(io: std.Io, allocator: std.mem.Allocator) !void {
//!     // 1. Initialize client (shares connections, spawns background event driver)
//!     var client = try curl.Client.init(allocator, io, .{
//!         .share_dns = true,
//!         .max_concurrency = 100, // Optional semaphore throttling
//!     });
//!     defer client.deinit();
//!
//!     // 2. Build and execute request asynchronously (buffered body)
//!     var res = try client.get("https://api.example.com/user/123")
//!         .headers(&.{
//!             .{ .name = "Accept", .value = "application/json" },
//!             .{ .name = "Authorization", .value = "Bearer my-secret-token" },
//!         })
//!         .timeout(5000)
//!         .send(io);
//!     defer res.deinit();
//!
//!     // 3. Strongly-typed JSON deserialization
//!     const User = struct { id: u64, name: []const u8 };
//!     const parsed = try res.json(User, .{});
//!     defer parsed.deinit();
//!     std.debug.print("User: {s}\n", .{parsed.value.name});
//!
//!     // 4. Or stream large response bodies incrementally with zero memory bloat
//!     var stream_res = try client.get("https://api.example.com/stream").sendStreaming(io);
//!     defer stream_res.deinit();
//!     var reader = stream_res.reader();
//!     while (try reader.interface.takeDelimiter('\n')) |line| {
//!         std.debug.print("Streamed line: {s}\n", .{line});
//!     }
//! }
//! ```
//!
//! ---
//!
//! ### 2. Low-Level Idiomatic API (`Easy`, `Multi`, & `Share`)
//!
//! Direct, 1-to-1 thin wrappers around libcurl's native C constructs (`CURL*`, `CURLM*`, `CURLSH*`).
//! Best suited for **simple CLI scripts, synchronous one-off requests, or custom I/O architectures**:
//!
//! - **`Easy`**: Synchronous transfer handle. Supports `fetch()` for simple GET/POST, as well as
//!   granular manual option configuration via dedicated setters (e.g. `setHeaders()`, `setUpload()`, `setMethod()`).
//! - **`Multi`**: Multi-transfer manager for callers implementing their own custom event loops or
//!   batch synchronous polling.
//! - **`Share`**: Explicit thread-safe sharing context for DNS, connection caches, and TLS sessions.
//!
//! **Example Usage**:
//! ```zig
//! const std = @import("std");
//! const curl = @import("curl");
//!
//! pub fn simpleGet(allocator: std.mem.Allocator, io: std.Io) !void {
//!     var ca_bundle = try curl.allocCABundle(allocator, io);
//!     defer ca_bundle.deinit(allocator);
//!
//!     // 1. Initialize Easy handle
//!     var easy = try curl.Easy.init(.{ .ca_bundle = ca_bundle });
//!     defer easy.deinit();
//!
//!     // 2. Synchronous in-place fetch with a custom writer buffer
//!     var buffer: [4096]u8 = undefined;
//!     var writer = std.Io.Writer.fixed(&buffer);
//!     const response = try easy.fetch("https://httpbin.org/get", .{ .writer = &writer });
//!
//!     std.debug.print("Status: {d}, Body: {s}\n", .{ response.status_code, writer.buffered() });
//! }
//! ```
//!
//! ---
//!
//! ### Summary: Which API should I use?
//!
//! | Requirements | Recommended API | Key Benefits |
//! | :--- | :--- | :--- |
//! | High-concurrency servers, microservices, async fibers | **`Client`** | Non-blocking `std.Io` fibers, handle pooling, fluent syntax, automatic JSON |
//! | Simple CLI tools, synchronous scripts, unit tests | **`Easy`** | Minimal overhead, zero background threads, simple `easy.fetch()` |
//! | Custom event loops, non-standard socket integration | **`Multi` / `libcurl`** | Direct raw C access, complete protocol control |
//!
const std = @import("std");
const util = @import("util.zig");
pub const checkCode = @import("errors.zig").checkCode;
pub const Diagnostics = @import("errors.zig").Diagnostics;

pub const Easy = @import("Easy.zig");
pub const Multi = @import("Multi.zig");
pub const MultiPart = @import("MultiPart.zig");
pub const Share = @import("Share.zig");
pub const Client = @import("Client.zig");
pub const Response = Client.Response;
pub const StreamingResponse = Client.StreamingResponse;
pub const BodyReader = Client.BodyReader;
pub const RequestBuilder = Client.RequestBuilder;

pub const printLibcurlVersion = util.printLibcurlVersion;
pub const hasParseHeaderSupport = util.hasParseHeaderSupport;
pub const urlEncode = util.urlEncode;
pub const allocCABundle = util.allocCABundle;
/// Expose the raw libcurl C bindings for advanced use cases.
pub const libcurl = util.c;

/// This function sets up the program environment that libcurl needs.
/// Since this function is not thread safe before libcurl 7.84.0, this function
/// must be called before the program calls any other function in libcurl.
/// A common place is in the beginning of the program. More see:
/// https://curl.se/libcurl/c/curl_global_init.html
pub fn globalInit() !void {
    try globalInitWithDiagnostics(null);
}

/// This variant of globalInit allows passing an optional Diagnostics pointer.
pub fn globalInitWithDiagnostics(diagnostics: ?*Diagnostics) !void {
    try checkCode(libcurl.curl_global_init(libcurl.CURL_GLOBAL_ALL), diagnostics);
}

/// This function releases resources acquired by curl_global_init.
pub fn globalDeinit() void {
    libcurl.curl_global_cleanup();
}

test {
    std.testing.refAllDecls(@This());
}

test "root: documentation fetchUser snippet compilable and functional" {
    const allocator = std.testing.allocator;
    const io = std.testing.io;

    // Local mock server for buffered JSON response
    const addr1 = std.Io.net.IpAddress{ .ip4 = std.Io.net.Ip4Address.loopback(0) };
    var s1 = try addr1.listen(io, .{ .mode = .stream });
    const p1 = s1.socket.address.getPort();

    const ServerContext = struct {
        server: std.Io.net.Server,
        io: std.Io,
        payload: []const u8,

        fn run(ctx: @This()) void {
            var s = ctx.server;
            defer s.deinit(ctx.io);

            const stream = s.accept(ctx.io) catch return;
            defer stream.close(ctx.io);

            var read_buf: [4096]u8 = undefined;
            var reader = std.Io.net.Stream.Reader.init(stream, ctx.io, &read_buf);
            var write_buf: [4096]u8 = undefined;
            var writer = std.Io.net.Stream.Writer.init(stream, ctx.io, &write_buf);

            var http_server = std.http.Server.init(&reader.interface, &writer.interface);
            var req = http_server.receiveHead() catch return;
            req.respond(ctx.payload, .{ .status = .ok, .keep_alive = false }) catch return;
        }
    };

    const t1 = try std.Thread.spawn(.{}, ServerContext.run, .{ServerContext{
        .server = s1,
        .io = io,
        .payload = "{\"id\":123,\"name\":\"Alice\"}",
    }});
    defer t1.join();

    // Local mock server for streaming response
    const addr2 = std.Io.net.IpAddress{ .ip4 = std.Io.net.Ip4Address.loopback(0) };
    var s2 = try addr2.listen(io, .{ .mode = .stream });
    const p2 = s2.socket.address.getPort();

    const t2 = try std.Thread.spawn(.{}, ServerContext.run, .{ServerContext{
        .server = s2,
        .io = io,
        .payload = "line1\nline2\n",
    }});
    defer t2.join();

    // 1. Initialize client (shares connections, spawns background event driver)
    var client = try Client.init(allocator, io, .{
        .share_dns = true,
        .load_ca_bundle = false,
        .max_concurrency = 100, // Optional semaphore throttling
    });
    defer client.deinit();

    const url1 = try allocator.printSentinel("http://127.0.0.1:{d}/user/123", .{p1}, 0);
    defer allocator.free(url1);

    // 2. Build and execute request asynchronously (buffered body)
    var res = try client.get(url1)
        .headers(&.{
            .{ .name = "Accept", .value = "application/json" },
            .{ .name = "Authorization", .value = "Bearer my-secret-token" },
        })
        .timeout(5000)
        .send(io);
    defer res.deinit();

    // 3. Strongly-typed JSON deserialization
    const User = struct { id: u64, name: []const u8 };
    const parsed = try res.json(User, .{});
    defer parsed.deinit();
    try std.testing.expectEqualStrings("Alice", parsed.value.name);

    // 4. Or stream large response bodies incrementally with zero memory bloat
    const url2 = try allocator.printSentinel("http://127.0.0.1:{d}/stream", .{p2}, 0);
    defer allocator.free(url2);

    var stream_res = try client.get(url2).sendStreaming(io);
    defer stream_res.deinit();
    var reader = stream_res.reader();
    var count: usize = 0;
    while (try reader.interface.takeDelimiter('\n')) |line| {
        if (count == 0) try std.testing.expectEqualStrings("line1", line);
        if (count == 1) try std.testing.expectEqualStrings("line2", line);
        count += 1;
    }
    try std.testing.expectEqual(@as(usize, 2), count);
}
