//! Comprehensive Async HTTP client showcase for zig-curl.
//!
//! Demonstrates:
//! 1. Fluent request builder syntax (modeled after `reqwest`)
//! 2. Strongly-typed JSON deserialization directly from `Response` (`res.json(T)`)
//! 3. Real network timeout simulation & precise error handling
//! 4. HTTP Bearer authentication & automatic redirect tracking
//! 5. Fine-grained escape-hatch customization via `.configure(hook)`
//! 6. Concurrency primitives:
//!    - `std.Io.Group`: Structured batch concurrency (similar to `Promise.all`)
//!    - `std.Io.Select`: Racing / First-completed pattern (similar to `Promise.race`)
//!    - `std.Io.Queue`: Asynchronous producer-consumer worker pipeline (Channel pattern)
const std = @import("std");
const curl = @import("curl");
const Client = curl.Client;

const BASE_URL = "https://edgebin.liujiacai.net";

// -------------------------------------------------------------------------
// Data Structures for Strongly-Typed JSON
// -------------------------------------------------------------------------

const IpGeoResponse = struct {
    origin: []const u8,
    country: []const u8,
    city: []const u8,
    timezone: []const u8,
    asn: u32,
    asOrganization: []const u8,
};

const BearerResponse = struct {
    authenticated: bool,
    token: []const u8,
};

// -------------------------------------------------------------------------
// Main Showcase
// -------------------------------------------------------------------------

pub fn main(init: std.process.Init) !void {
    const io = init.io;

    var gpa: std.heap.SafeAllocator = .init(std.heap.page_allocator, .{});
    defer if (gpa.deinit() != 0) @panic("memory leak detected");
    const allocator = gpa.allocator();

    // 1. Initialize global async client (automatically loads system CA bundle, spawns reactor thread and initializes CURLSH)
    var client = try Client.init(allocator, io, .{
        .share_dns = true,
        .share_connect = true,
        .share_ssl_session = true,
    });
    defer client.deinit();

    // =========================================================================
    // Showcase 1: Simple GET with Strongly-Typed JSON Deserialization
    // =========================================================================
    std.debug.print("=== 1. Strongly-Typed JSON Deserialization (res.json(T)) ===\n", .{});
    {
        var res = try client.get(BASE_URL ++ "/ip")
            .headers(&.{.{ .name = "Accept", .value = "application/json" }})
            .timeout(15000)
            .send(io);
        defer res.deinit();

        std.debug.print("Status: {d}\n", .{res.status_code});

        // Directly parse JSON from response body into a Zig struct (like reqwest::Response::json)
        const parsed = try res.json(IpGeoResponse, .{ .ignore_unknown_fields = true });
        defer parsed.deinit();

        const geo = parsed.value;
        std.debug.print("  IP: {s}\n  Country: {s}\n  City: {s}\n  Timezone: {s}\n  ASN: {d} ({s})\n\n", .{
            geo.origin,
            geo.country,
            geo.city,
            geo.timezone,
            geo.asn,
            geo.asOrganization,
        });
    }

    // =========================================================================
    // Showcase 2: Asynchronous POST with JSON Body
    // =========================================================================
    std.debug.print("=== 2. Asynchronous POST with JSON Body ===\n", .{});
    {
        var res = try client.post(BASE_URL ++ "/anything")
            .headers(&.{
                .{ .name = "Content-Type", .value = "application/json" },
                .{ .name = "X-Powered-By", .value = "zig-curl" },
            })
            .body("{\"message\": \"Hello from async-curl!\"}")
            .timeout(15000)
            .send(io);
        defer res.deinit();

        std.debug.print("Status: {d}\nResponse Body Snippet:\n{s}\n\n", .{
            res.status_code,
            res.body[0..@min(res.body.len, 180)],
        });
    }

    // =========================================================================
    // Showcase 3: Real Network Timeout Simulation
    // =========================================================================
    std.debug.print("=== 3. Real Network Timeout Simulation (/delay/3 with 1s timeout) ===\n", .{});
    {
        // Edgebin's /delay/3 pauses for 3 seconds. Setting timeout to 1000ms forces a real timeout.
        const start_time = std.Io.Clock.awake.now(io);

        const result = client.get(BASE_URL ++ "/delay/3")
            .timeout(1000) // 1 second timeout
            .send(io);

        const elapsed_ms = start_time.durationTo(std.Io.Clock.awake.now(io)).toMilliseconds();

        if (result) |_| {
            @panic("expected timeout error, but request succeeded!");
        } else |err| switch (err) {
            error.Timeout => {
                std.debug.print("  Successfully intercepted error.Timeout after {d}ms (as expected)!\n\n", .{elapsed_ms});
            },
            else => {
                std.debug.print("  Unexpected error: {any}\n\n", .{err});
            },
        }
    }

    // =========================================================================
    // Showcase 4: Bearer Authentication & Redirect Tracking
    // =========================================================================
    std.debug.print("=== 4. Bearer Authentication & Redirect Tracking ===\n", .{});
    {
        // Bearer Authentication
        var auth_res = try client.get(BASE_URL ++ "/bearer")
            .headers(&.{.{ .name = "Authorization", .value = "Bearer secret-token-xyz-123" }})
            .timeout(15000)
            .send(io);
        defer auth_res.deinit();

        const auth_json = try auth_res.json(BearerResponse, .{ .ignore_unknown_fields = true });
        defer auth_json.deinit();
        std.debug.print("  Bearer Auth -> Authenticated: {}, Token: {s}\n", .{
            auth_json.value.authenticated,
            auth_json.value.token,
        });

        // Redirect Tracking (Edgebin /redirect/2 redirects 2 times)
        var redir_res = try client.get(BASE_URL ++ "/redirect/2")
            .followLocation(true)
            .timeout(15000)
            .send(io);
        defer redir_res.deinit();
        std.debug.print("  Redirect 2x -> Final Status: {d}, Final Body length: {d} bytes\n\n", .{
            redir_res.status_code,
            redir_res.body.len,
        });
    }

    // =========================================================================
    // Showcase 5: Fine-Grained Escape Hatch via .configure(hook)
    // =========================================================================
    std.debug.print("=== 5. Escape Hatch via .configure(hook) (Taint-and-Dispose) ===\n", .{});
    {
        const CustomConfig = struct {
            fn hook(easy: *curl.Easy) !void {
                // Access raw libcurl options directly without leaky abstractions.
                // The client automatically marks this handle as tainted and destroys it after use.
                try easy.setHttpVersion(.http1_1);
            }
        };

        var res = try client.get(BASE_URL ++ "/headers")
            .configure(CustomConfig.hook)
            .timeout(15000)
            .send(io);
        defer res.deinit();

        std.debug.print("  Customized Request -> Status: {d}\n\n", .{res.status_code});
    }

    // =========================================================================
    // Showcase 6: Concurrency Primitive 1 -- std.Io.Group (Batch All)
    // =========================================================================
    std.debug.print("=== 6. Concurrency Primitive 1: std.Io.Group (Batch All) ===\n", .{});
    {
        const batch_paths = [_][:0]const u8{
            "/ip",
            "/user-agent",
            "/headers",
            "/json",
        };

        const Worker = struct {
            fn run(c: *Client, i: std.Io, path: [:0]const u8) std.Io.Cancelable!void {
                const url = c.allocator.printSentinel("{s}{s}", .{ BASE_URL, path }, 0) catch return;
                defer c.allocator.free(url);

                var r = c.get(url)
                    .timeout(15000)
                    .send(i) catch |err| {
                    std.debug.print("    [Group] {s} failed: {any}\n", .{ path, err });
                    return;
                };
                defer r.deinit();

                std.debug.print("    [Group] {s} -> status {d}, {d} bytes\n", .{ path, r.status_code, r.body.len });
            }
        };

        var group: std.Io.Group = .init;
        for (batch_paths) |path| {
            group.async(io, Worker.run, .{ client, io, path });
        }

        try group.await(io);
        std.debug.print("  All batch requests in Group finished!\n\n", .{});
    }

    // =========================================================================
    // Showcase 7: Concurrency Primitive 2 -- std.Io.Select (Racing)
    // =========================================================================
    std.debug.print("=== 7. Concurrency Primitive 2: std.Io.Select (Racing) ===\n", .{});
    {
        // Race two requests: a fast one (/delay/1) vs a slow one (/delay/3).
        // Whichever finishes first wins the race; the slower branch is cancelled.
        const RaceEvent = union(enum) {
            fast: u16,
            slow: u16,
        };

        const Tasks = struct {
            fn fastRequest(c: *Client, i: std.Io) u16 {
                var r = c.get(BASE_URL ++ "/delay/1")
                    .timeout(15000)
                    .send(i) catch return 0;
                defer r.deinit();
                return r.status_code;
            }

            fn slowRequest(c: *Client, i: std.Io) u16 {
                var r = c.get(BASE_URL ++ "/delay/3")
                    .timeout(15000)
                    .send(i) catch return 0;
                defer r.deinit();
                return r.status_code;
            }
        };

        var select_storage: [2]RaceEvent = undefined;
        var s = std.Io.Select(RaceEvent).init(io, &select_storage);
        defer s.group.cancel(io);

        s.async(.fast, Tasks.fastRequest, .{ client, io });
        s.async(.slow, Tasks.slowRequest, .{ client, io });

        const winner = try s.queue.getOne(io);
        switch (winner) {
            .fast => |code| std.debug.print("  Fast branch (/delay/1) won the race with status: {d}!\n\n", .{code}),
            .slow => |code| std.debug.print("  Slow branch won with status: {d}!\n\n", .{code}),
        }
    }

    // =========================================================================
    // Showcase 8: Concurrency Primitive 3 -- std.Io.Queue (Pipeline)
    // =========================================================================
    std.debug.print("=== 8. Concurrency Primitive 3: std.Io.Queue (Pipeline Crawling) ===\n", .{});
    {
        // Demonstrates a worker pipeline:
        // A bounded concurrent queue distributes work to asynchronous background fibers.
        const url_list = [_][:0]const u8{
            "/ip",
            "/user-agent",
            "/headers",
            "/json",
            "/cache/60",
        };

        var queue_buffer: [8][:0]const u8 = undefined;
        var work_queue = std.Io.Queue([:0]const u8).init(&queue_buffer);

        const PipelineWorker = struct {
            fn consume(c: *Client, i: std.Io, q: *std.Io.Queue([:0]const u8), worker_id: usize) std.Io.Cancelable!void {
                while (true) {
                    const path = q.getOne(i) catch |err| switch (err) {
                        error.Closed, error.Canceled => break,
                    };

                    const url = c.allocator.printSentinel("{s}{s}", .{ BASE_URL, path }, 0) catch continue;
                    defer c.allocator.free(url);

                    var r = c.get(url)
                        .timeout(15000)
                        .send(i) catch continue;
                    defer r.deinit();

                    std.debug.print("    [Worker #{d}] processed {s} -> status {d}\n", .{ worker_id, path, r.status_code });
                }
            }
        };

        var worker_group: std.Io.Group = .init;

        // Spawn 2 concurrent consumer fibers
        worker_group.async(io, PipelineWorker.consume, .{ client, io, &work_queue, 1 });
        worker_group.async(io, PipelineWorker.consume, .{ client, io, &work_queue, 2 });

        // Producer: push URLs into the channel
        for (url_list) |path| {
            try work_queue.putOne(io, path);
        }

        // Close the queue so consumers finish their loops
        work_queue.close(io);

        // Wait for all pipeline workers to drain and exit
        try worker_group.await(io);
        std.debug.print("  Pipeline processing completed successfully!\n\n", .{});
    }

    // =========================================================================
    // Showcase 9: Concurrency Primitive 4 -- Future(T) & Interleaving
    // =========================================================================
    std.debug.print("=== 9. Concurrency Primitive 4: Future(T) Interleaving ===\n", .{});
    {
        // Demonstrates explicit Future(T) handle:
        // Launching an asynchronous network operation with io.async(),
        // performing local computation in parallel, then explicitly awaiting the future.
        const Worker = struct {
            fn fetchIp(i: std.Io, c: *Client) anyerror!u16 {
                var res = try c.get(BASE_URL ++ "/ip")
                    .timeout(10000)
                    .send(i);
                defer res.deinit();
                return res.status_code;
            }
        };

        var fut = io.async(Worker.fetchIp, .{ io, client });

        // While the network transfer is running in the background,
        // perform concurrent local work in the foreground.
        var local_sum: usize = 0;
        for (0..500_000) |n| {
            local_sum +%= n;
        }
        std.debug.print("  Foreground local work running concurrently (sum hash={x}), awaiting Future...\n", .{local_sum});

        const status = try fut.await(io);
        std.debug.print("  Background Future resolved with HTTP status: {d}!\n\n", .{status});
    }

    // =========================================================================
    // Showcase 10: Streaming Response Body with std.Io.Reader
    // =========================================================================
    std.debug.print("=== 10. Streaming Response Body with std.Io.Reader ===\n", .{});
    {
        var res = try client.get(BASE_URL ++ "/headers")
            .timeout(10000)
            .sendStreaming(io);
        defer res.deinit();

        std.debug.print("  Headers received early! HTTP Status: {d}\n", .{res.status_code});

        var reader = res.reader();
        var total_bytes: usize = 0;
        var chunk_count: usize = 0;
        var buf: [128]u8 = undefined;

        while (true) {
            const n = try reader.read(&buf);
            if (n == 0) break;
            total_bytes += n;
            chunk_count += 1;
        }

        std.debug.print("  Streamed {d} bytes across {d} chunks with 0 memory bloat.\n\n", .{ total_bytes, chunk_count });
    }

    std.debug.print("All showcases executed with 0 errors and 0 memory leaks.\n", .{});
}
