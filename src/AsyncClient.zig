//! `AsyncClient` provides an asynchronous, high-throughput, structured HTTP client
//! integrating libcurl's multi-handle with Zig 0.17's `std.Io` concurrency runtime.
//!
//! Thread Safety Contract:
//! - `allocator`: Must be thread-safe (e.g. `std.heap.c_allocator`). The background reactor
//!   thread allocates response buffers dynamically during write callbacks concurrently
//!   with user requests.
//! - `io`: Must be a thread-safe `std.Io` implementation because `ctx.event.set(ctx.io)`
//!   is executed from the background driver loop to awaken waiting tasks across threads.
//! - `deinit`: The caller must ensure that all concurrent `send()` calls have finished
//!   before calling `deinit()`.
//!
//! Features:
//! - Fluent `RequestBuilder` API with zero heap allocation and standard slice syntax
//! - Transparent connection, DNS, and TLS session reuse via `CURLSH`
//! - Clean Easy handle pooling with automatic Taint-and-Dispose isolation
//! - Non-blocking fiber suspension and resumption via `std.Io.Event`
const std = @import("std");
const errors = @import("errors.zig");
const util = @import("util.zig");
const Easy = @import("Easy.zig");
const Multi = @import("Multi.zig");
const Share = @import("Share.zig");

const c = util.c;
const assert = std.debug.assert;
const checkCode = errors.checkCode;
const checkMCode = errors.checkMCode;
const Allocator = std.mem.Allocator;
const Writer = std.Io.Writer;
const SpinLock = Share.SpinLock;
const ResizableBuffer = util.ResizableBuffer;
const Self = @This();

allocator: Allocator,
share: *Share,
multi: *c.CURLM,
pool: HandlePool,
running: std.atomic.Value(bool),
driver_thread: std.Thread,
options: Options,
semaphore: ?std.Io.Semaphore = null,

ca_bundle: ?ResizableBuffer = null,
owns_ca_bundle: bool = false,

queue_mutex: SpinLock = .{},
pending_queue: ?*RequestContext = null,
active_list: ?*RequestContext = null,

pub const HeaderEntry = struct {
    name: []const u8,
    value: []const u8,
};

pub const Response = struct {
    allocator: Allocator,
    status_code: u16,
    body: []const u8,

    pub fn deinit(self: *Response) void {
        self.allocator.free(self.body);
    }

    /// Parse response body as JSON into the specified type `T`.
    /// Directly mirrors `reqwest`'s `response.json::<T>().await`.
    pub fn json(
        self: *Response,
        comptime T: type,
        options: std.json.ParseOptions,
    ) !std.json.Parsed(T) {
        return std.json.parseFromSlice(T, self.allocator, self.body, options);
    }
};

pub const RequestContext = struct {
    io: std.Io,
    easy: *Easy,
    event: std.Io.Event = .unset,
    result: c.CURLcode = c.CURLE_OK,
    response_code: c_long = 0,
    body_writer: std.Io.Writer.Allocating,
    c_headers: ?*c.struct_curl_slist = null,
    next: ?*RequestContext = null,
    active_next: ?*RequestContext = null,
    active_prev: ?*RequestContext = null,
};

const HandlePool = struct {
    mutex: SpinLock = .{},
    items: std.ArrayList(*Easy) = .empty,

    fn deinit(self: *HandlePool, allocator: Allocator) void {
        self.mutex.lock();
        defer self.mutex.unlock();

        for (self.items.items) |easy| {
            easy.deinit();
            allocator.destroy(easy);
        }
        self.items.deinit(allocator);
    }

    fn acquire(self: *HandlePool) ?*Easy {
        self.mutex.lock();
        defer self.mutex.unlock();

        if (self.items.items.len > 0) {
            return self.items.pop();
        }
        return null;
    }

    fn release(self: *HandlePool, allocator: Allocator, easy: *Easy) !void {
        self.mutex.lock();
        defer self.mutex.unlock();

        // Limit maximum pool capacity to prevent unbounded idle memory growth.
        const pool_max_capacity = 64;
        if (self.items.items.len < pool_max_capacity) {
            try self.items.append(allocator, easy);
        } else {
            easy.deinit();
            allocator.destroy(easy);
        }
    }
};

pub const Options = struct {
    share_dns: bool = true,
    share_connect: bool = true,
    share_ssl_session: bool = true,
    /// Explicit CA bundle override. If null and load_ca_bundle is true,
    /// AsyncClient will automatically call util.allocCABundle(allocator, io).
    ca_bundle: ?ResizableBuffer = null,
    /// Whether to automatically allocate the system CA bundle when ca_bundle is null.
    load_ca_bundle: bool = true,
    /// Maximum concurrent in-flight HTTP requests allowed.
    /// When specified, `send` will wait on a `std.Io.Semaphore` before dispatching.
    max_concurrency: ?usize = null,
};

pub fn init(allocator: Allocator, io: std.Io, options: Options) !*Self {
    const self = try allocator.create(Self);
    errdefer allocator.destroy(self);

    var ca_bundle: ?ResizableBuffer = null;
    var owns_ca_bundle: bool = false;
    if (options.ca_bundle) |bundle| {
        ca_bundle = bundle;
        owns_ca_bundle = false;
    } else if (options.load_ca_bundle) {
        ca_bundle = try util.allocCABundle(allocator, io);
        owns_ca_bundle = true;
    }
    errdefer if (owns_ca_bundle) {
        if (ca_bundle) |*b| b.deinit(allocator);
    };

    const share = try Share.init(allocator, .{
        .share_dns = options.share_dns,
        .share_connect = options.share_connect,
        .share_ssl_session = options.share_ssl_session,
    });
    errdefer share.deinit();

    const multi = c.curl_multi_init() orelse return error.InitMultiFailed;
    errdefer assert(c.curl_multi_cleanup(multi) == c.CURLM_OK);

    self.* = .{
        .allocator = allocator,
        .share = share,
        .multi = multi,
        .pool = .{},
        .running = std.atomic.Value(bool).init(true),
        .driver_thread = undefined,
        .options = options,
        .semaphore = if (options.max_concurrency) |limit| .{ .permits = limit } else null,
        .ca_bundle = ca_bundle,
        .owns_ca_bundle = owns_ca_bundle,
    };

    self.driver_thread = try std.Thread.spawn(.{}, driverLoop, .{self});
    return self;
}

pub fn deinit(self: *Self) void {
    self.running.store(false, .release);
    const wakeup_rc = c.curl_multi_wakeup(self.multi);
    assert(wakeup_rc == c.CURLM_OK);
    self.driver_thread.join();

    self.pool.deinit(self.allocator);
    const cleanup_rc = c.curl_multi_cleanup(self.multi);
    assert(cleanup_rc == c.CURLM_OK);
    self.share.deinit();

    if (self.owns_ca_bundle) {
        if (self.ca_bundle) |*b| b.deinit(self.allocator);
    }

    const allocator = self.allocator;
    allocator.destroy(self);
}

// -------------------------------------------------------------------------
// Fluent Request Builders
// -------------------------------------------------------------------------

pub fn get(self: *Self, url: [:0]const u8) RequestBuilder {
    return RequestBuilder.init(self, .GET, url);
}

pub fn post(self: *Self, url: [:0]const u8) RequestBuilder {
    return RequestBuilder.init(self, .POST, url);
}

pub fn put(self: *Self, url: [:0]const u8) RequestBuilder {
    return RequestBuilder.init(self, .PUT, url);
}

pub fn delete(self: *Self, url: [:0]const u8) RequestBuilder {
    return RequestBuilder.init(self, .DELETE, url);
}

pub fn head(self: *Self, url: [:0]const u8) RequestBuilder {
    return RequestBuilder.init(self, .HEAD, url);
}

pub fn patch(self: *Self, url: [:0]const u8) RequestBuilder {
    return RequestBuilder.init(self, .PATCH, url);
}

pub fn request(self: *Self, method: Easy.Method, url: [:0]const u8) RequestBuilder {
    return RequestBuilder.init(self, method, url);
}

// -------------------------------------------------------------------------
// Internal Engine Execution
// -------------------------------------------------------------------------

fn acquireHandle(self: *Self) !*Easy {
    if (self.pool.acquire()) |easy| {
        return easy;
    }
    return self.createFreshHandle();
}

fn createFreshHandle(self: *Self) !*Easy {
    const easy = try self.allocator.create(Easy);
    errdefer self.allocator.destroy(easy);

    easy.* = try Easy.init(.{
        .ca_bundle = self.ca_bundle,
    });
    errdefer easy.deinit();

    // Attach global shared handle to enable connection and cache reuse.
    try easy.setShare(self.share.handle);
    return easy;
}

fn releaseHandle(self: *Self, easy: *Easy, is_tainted: bool) void {
    if (is_tainted) {
        // Tainted handles are disposable to prevent configuration pollution.
        easy.deinit();
        self.allocator.destroy(easy);
    } else {
        easy.reset();
        // Re-attach share handle after curl_easy_reset
        easy.setShare(self.share.handle) catch {
            easy.deinit();
            self.allocator.destroy(easy);
            return;
        };
        self.pool.release(self.allocator, easy) catch {
            easy.deinit();
            self.allocator.destroy(easy);
        };
    }
}

fn driverLoop(self: *Self) void {
    while (self.running.load(.acquire)) {
        self.drainPendingQueue();

        var num_fds: c_int = 0;
        const poll_rc = c.curl_multi_poll(self.multi, null, 0, 100, &num_fds);
        assert(poll_rc == c.CURLM_OK);

        var still_running: c_int = 0;
        const perform_rc = c.curl_multi_perform(self.multi, &still_running);
        assert(perform_rc == c.CURLM_OK);

        self.processDoneTransfers();
    }

    // Drain remaining transfers on shutdown with bounded iterations (max ~5s)
    self.drainPendingQueue();
    var still_running: c_int = 1;
    var drain_iters: usize = 0;
    while (still_running > 0 and drain_iters < 100) : (drain_iters += 1) {
        const drain_perform_rc = c.curl_multi_perform(self.multi, &still_running);
        assert(drain_perform_rc == c.CURLM_OK);
        self.processDoneTransfers();
        var num_fds: c_int = 0;
        const drain_poll_rc = c.curl_multi_poll(self.multi, null, 0, 50, &num_fds);
        assert(drain_poll_rc == c.CURLM_OK);
    }

    // If any active transfers remain in multi after shutdown drain, abort and remove them
    var curr_active = self.active_list;
    while (curr_active) |ctx| {
        const next = ctx.active_next;
        const remove_rc = c.curl_multi_remove_handle(self.multi, ctx.easy.handle);
        assert(remove_rc == c.CURLM_OK);
        ctx.result = c.CURLE_ABORTED_BY_CALLBACK;
        if (ctx.c_headers) |h| {
            c.curl_slist_free_all(h);
            ctx.c_headers = null;
        }
        ctx.event.set(ctx.io);
        curr_active = next;
    }
    self.active_list = null;

    // Also cancel any unhandled items left in pending_queue
    self.queue_mutex.lock();
    var unhandled = self.pending_queue;
    self.pending_queue = null;
    self.queue_mutex.unlock();
    while (unhandled) |ctx| {
        const next = ctx.next;
        ctx.result = c.CURLE_ABORTED_BY_CALLBACK;
        if (ctx.c_headers) |h| {
            c.curl_slist_free_all(h);
            ctx.c_headers = null;
        }
        ctx.event.set(ctx.io);
        unhandled = next;
    }
}

fn drainPendingQueue(self: *Self) void {
    self.queue_mutex.lock();
    var item = self.pending_queue;
    self.pending_queue = null;
    self.queue_mutex.unlock();

    while (item) |ctx| {
        const next = ctx.next;
        const rc = c.curl_multi_add_handle(self.multi, ctx.easy.handle);
        if (rc != c.CURLM_OK) {
            ctx.result = c.CURLE_FAILED_INIT;
            ctx.event.set(ctx.io);
        } else {
            ctx.active_next = self.active_list;
            ctx.active_prev = null;
            if (self.active_list) |active_head| {
                active_head.active_prev = ctx;
            }
            self.active_list = ctx;
        }
        item = next;
    }
}

fn processDoneTransfers(self: *Self) void {
    var msgs_left: c_int = 0;
    while (true) {
        const msg = c.curl_multi_info_read(self.multi, &msgs_left);
        if (msg == null) break;

        if (msg.*.msg == c.CURLMSG_DONE) {
            const easy_handle = msg.*.easy_handle.?;
            var private_ptr: ?*anyopaque = null;
            const info_rc = c.curl_easy_getinfo(easy_handle, c.CURLINFO_PRIVATE, &private_ptr);
            assert(info_rc == c.CURLE_OK);

            if (private_ptr) |ptr| {
                const ctx: *RequestContext = @ptrCast(@alignCast(ptr));

                // Unlink from active_list
                if (ctx.active_prev) |prev| {
                    prev.active_next = ctx.active_next;
                } else {
                    self.active_list = ctx.active_next;
                }
                if (ctx.active_next) |act_next| {
                    act_next.active_prev = ctx.active_prev;
                }
                ctx.active_prev = null;
                ctx.active_next = null;

                ctx.result = msg.*.data.result;

                var code: c_long = 0;
                const resp_rc = c.curl_easy_getinfo(
                    easy_handle,
                    c.CURLINFO_RESPONSE_CODE,
                    &code,
                );
                assert(resp_rc == c.CURLE_OK);
                ctx.response_code = code;

                const remove_rc = c.curl_multi_remove_handle(self.multi, easy_handle);
                assert(remove_rc == c.CURLM_OK);

                if (ctx.c_headers) |h| {
                    c.curl_slist_free_all(h);
                    ctx.c_headers = null;
                }

                // Notify waiting fiber/thread
                ctx.event.set(ctx.io);
            }
        }
    }
}

// -------------------------------------------------------------------------
// RequestBuilder Implementation
// -------------------------------------------------------------------------

pub const RequestBuilder = struct {
    client: *Self,
    method: Easy.Method,
    url: [:0]const u8,
    custom_headers: []const HeaderEntry = &.{},
    body_data: ?[]const u8 = null,
    timeout_ms: ?usize = null,
    http_version: ?Easy.HttpVersion = null,
    follow_location: bool = true,
    unix_socket_path: ?[:0]const u8 = null,
    is_tainted: bool = false,
    config_hook: ?*const fn (*Easy) anyerror!void = null,

    fn init(client: *Self, method: Easy.Method, url: [:0]const u8) RequestBuilder {
        return .{
            .client = client,
            .method = method,
            .url = url,
            .custom_headers = &.{},
        };
    }

    /// Sets custom HTTP request headers from a borrowed slice.
    ///
    /// Lifetime contract: The caller must ensure that the slice `h` remains
    /// valid during the synchronous invocation of `send(io)`. Once `send(io)`
    /// populates the internal `curl_slist`, the slice memory is no longer referenced.
    pub fn headers(self: RequestBuilder, h: []const HeaderEntry) RequestBuilder {
        var s = self;
        s.custom_headers = h;
        return s;
    }

    /// Sets raw request body data from a borrowed slice.
    ///
    /// Lifetime contract: The caller must ensure that `data` remains valid
    /// until `send(io)` completes and returns, as libcurl reads this buffer
    /// directly via CURLOPT_POSTFIELDS during the entire network transfer.
    pub fn body(self: RequestBuilder, data: []const u8) RequestBuilder {
        var s = self;
        s.body_data = data;
        return s;
    }

    pub fn timeout(self: RequestBuilder, ms: usize) RequestBuilder {
        var s = self;
        s.timeout_ms = ms;
        return s;
    }

    pub fn version(self: RequestBuilder, ver: Easy.HttpVersion) RequestBuilder {
        var s = self;
        s.http_version = ver;
        return s;
    }

    pub fn followLocation(self: RequestBuilder, enable: bool) RequestBuilder {
        var s = self;
        s.follow_location = enable;
        return s;
    }

    pub fn unixSocket(self: RequestBuilder, path: [:0]const u8) RequestBuilder {
        var s = self;
        s.unix_socket_path = path;
        s.is_tainted = true; // Unix domain sockets alter connection routing
        return s;
    }

    /// Attach a custom configuration hook for 100% native libcurl option customization.
    /// This immediately marks the request as Tainted, ensuring the handle is disposed of
    /// after use rather than returned to the clean pool.
    pub fn configure(self: RequestBuilder, hook: *const fn (*Easy) anyerror!void) RequestBuilder {
        var s = self;
        s.config_hook = hook;
        s.is_tainted = true;
        return s;
    }

    /// Send the HTTP request asynchronously and suspend until the response is ready.
    pub fn send(self: RequestBuilder, io: std.Io) !Response {
        const client = self.client;

        // Apply concurrency rate-limiting if configured.
        if (client.semaphore) |*sem| {
            try sem.wait(io);
        }
        defer {
            if (client.semaphore) |*sem| {
                sem.post(io);
            }
        }

        const easy = if (self.is_tainted)
            try client.createFreshHandle()
        else
            try client.acquireHandle();

        defer client.releaseHandle(easy, self.is_tainted);

        var context = RequestContext{
            .io = io,
            .easy = easy,
            .body_writer = std.Io.Writer.Allocating.init(client.allocator),
            .c_headers = null,
        };
        errdefer context.body_writer.deinit();

        try easy.setUrl(self.url);
        try easy.setMethod(self.method);
        try easy.setWriter(&context.body_writer.writer);
        try easy.setFollowLocation(self.follow_location);

        if (self.timeout_ms) |ms| {
            easy.timeout_ms = ms;
        }
        if (self.http_version) |ver| {
            try easy.setHttpVersion(ver);
        }
        if (self.unix_socket_path) |path| {
            try easy.setUnixSocketPath(path);
        }
        if (self.body_data) |b| {
            try easy.setPostFields(b);
        }

        // Build native curl slist for custom headers
        if (self.custom_headers.len > 0) {
            var ch: ?*c.struct_curl_slist = null;
            errdefer if (ch) |h| c.curl_slist_free_all(h);
            for (self.custom_headers) |h| {
                const line = try client.allocator.printSentinel(
                    "{s}: {s}",
                    .{ h.name, h.value },
                    0,
                );
                defer client.allocator.free(line);
                ch = c.curl_slist_append(ch, line.ptr) orelse return error.OutOfMemory;
            }
            context.c_headers = ch;
            if (ch) |headers_list| {
                try easy.setHeadersC(headers_list);
            }
        }
        errdefer if (context.c_headers) |h| {
            c.curl_slist_free_all(h);
            context.c_headers = null;
        };

        // Apply common options (user agent, ca bundle, timeout)
        try easy.setCommonOpts();

        // Apply user configuration hook if present
        if (self.config_hook) |hook| {
            try hook(easy);
        }

        try easy.setPrivate(&context);

        // Push to pending queue and wake up driver
        {
            client.queue_mutex.lock();
            context.next = client.pending_queue;
            client.pending_queue = &context;
            client.queue_mutex.unlock();
        }

        const wakeup_rc = c.curl_multi_wakeup(client.multi);
        assert(wakeup_rc == c.CURLM_OK);

        // Suspend current fiber/thread until completion.
        // We protect this section from cancellation to prevent stack memory Use-After-Free
        // (since `context` is stack-allocated) and to prevent easy handle state tearing
        // while the driver thread is actively executing the transfer in curl_multi.
        context.event.waitUncancelable(io);

        if (context.result != c.CURLE_OK) {
            // Note: context.body_writer.deinit() is handled by errdefer above!
            if (context.result == c.CURLE_OPERATION_TIMEDOUT) {
                return error.Timeout;
            }
            return error.HttpTransferFailed;
        }

        return Response{
            .allocator = client.allocator,
            .status_code = @intCast(context.response_code),
            .body = try context.body_writer.toOwnedSlice(),
        };
    }
};

// -------------------------------------------------------------------------
// Unit Tests
// -------------------------------------------------------------------------

test "AsyncClient: init and deinit lifecycle" {
    // Verifies that AsyncClient and its background worker thread can be started
    // and stopped cleanly without resource leaks or thread hangs.
    const allocator = std.testing.allocator;
    const io = std.testing.io;

    var client = try Self.init(allocator, io, .{});
    defer client.deinit();

    assert(client.running.load(.acquire) == true);
    // Verifies that internal CA bundle was automatically loaded and is owned
    assert(client.owns_ca_bundle == true);
    assert(client.ca_bundle != null);
}

test "AsyncClient: handle pool reuse and taint isolation" {
    // Verifies the core pool architecture:
    // 1. Clean handles are returned to the pool after execution
    // 2. Tainted handles (with custom configure hook) are destroyed rather than pooled
    const allocator = std.testing.allocator;
    const io = std.testing.io;

    var client = try Self.init(allocator, io, .{});
    defer client.deinit();

    // Pool starts empty
    assert(client.pool.items.items.len == 0);

    // Acquire a clean handle
    const h1 = try client.acquireHandle();
    assert(client.pool.items.items.len == 0);

    // Release clean handle -> returns to pool
    client.releaseHandle(h1, false);
    assert(client.pool.items.items.len == 1);

    // Acquire another handle -> should reuse from pool
    const h2 = try client.acquireHandle();
    assert(h2 == h1);
    assert(client.pool.items.items.len == 0);

    // Release tainted handle -> destroyed immediately, pool remains empty
    client.releaseHandle(h2, true);
    assert(client.pool.items.items.len == 0);
}

test "AsyncClient: RequestBuilder configuration chaining" {
    // Verifies that the fluent RequestBuilder records all configuration options
    // and correctly toggles is_tainted when dangerous/hook operations are applied.
    const allocator = std.testing.allocator;
    const io = std.testing.io;

    var client = try Self.init(allocator, io, .{});
    defer client.deinit();

    // Standard request: clean by default, value semantics
    const req1 = client.get("https://example.com")
        .headers(&.{
            .{ .name = "Accept", .value = "text/html" },
            .{ .name = "User-Agent", .value = "zig-curl" },
        })
        .timeout(3000)
        .version(.http2)
        .followLocation(false);

    assert(req1.is_tainted == false);
    assert(req1.timeout_ms.? == 3000);
    assert(req1.http_version.? == .http2);
    assert(req1.follow_location == false);
    assert(req1.custom_headers.len == 2);

    // Customized request with configure hook: automatically tainted
    const Custom = struct {
        fn hook(easy: *Easy) !void {
            _ = easy;
        }
    };
    const req2 = client.post("https://example.com")
        .configure(Custom.hook);
    assert(req2.is_tainted == true);

    // Unix domain socket request: automatically tainted
    const req3 = client.get("http://localhost/info")
        .unixSocket("/var/run/test.sock");
    assert(req3.is_tainted == true);
}

test "AsyncClient: max_concurrency semaphore integration" {
    // Verifies that specifying max_concurrency properly initializes the Semaphore
    // and correctly acquires and posts permits during asynchronous execution.
    const allocator = std.testing.allocator;
    const io = std.testing.io;

    var client = try Self.init(allocator, io, .{
        .max_concurrency = 2,
    });
    defer client.deinit();

    // Verify semaphore is active with 2 permits
    assert(client.semaphore != null);
    assert(client.semaphore.?.permits == 2);

    // Acquire one permit
    try client.semaphore.?.wait(io);
    assert(client.semaphore.?.permits == 1);

    // Acquire second permit
    try client.semaphore.?.wait(io);
    assert(client.semaphore.?.permits == 0);

    // Release both permits
    client.semaphore.?.post(io);
    assert(client.semaphore.?.permits == 1);
    client.semaphore.?.post(io);
    assert(client.semaphore.?.permits == 2);
}

test "AsyncClient: uncancelable event wait safety" {
    // Verifies that RequestContext event completion can be awaited uncancelably
    // without prematurely exiting or destroying stack data when signals arrive.
    const io = std.testing.io;

    var event: std.Io.Event = .unset;
    assert(event.isSet() == false);

    const SetterThread = struct {
        fn run(ev: *std.Io.Event, test_io: std.Io) void {
            // Signal event
            ev.set(test_io);
        }
    };

    const thread = try std.Thread.spawn(.{}, SetterThread.run, .{ &event, io });
    thread.join();

    // waitUncancelable must observe the set event immediately without returning error.Canceled
    event.waitUncancelable(io);
    assert(event.isSet() == true);
}

fn startMockServer(response_data: []const u8) !struct { thread: std.Thread, port: u16 } {
    const C = struct {
        extern "c" fn socket(domain: c_int, sock_type: c_int, protocol: c_int) c_int;
        extern "c" fn bind(fd: c_int, addr: *const anyopaque, len: c_uint) c_int;
        extern "c" fn listen(fd: c_int, backlog: c_int) c_int;
        extern "c" fn accept(fd: c_int, addr: ?*anyopaque, len: ?*c_uint) c_int;
        extern "c" fn getsockname(fd: c_int, addr: *anyopaque, len: *c_uint) c_int;
        extern "c" fn close(fd: c_int) c_int;
        extern "c" fn write(fd: c_int, buf: [*]const u8, count: usize) isize;
        extern "c" fn read(fd: c_int, buf: [*]u8, count: usize) isize;
    };

    const fd = C.socket(2, 1, 0); // AF_INET, SOCK_STREAM
    assert(fd >= 0);

    var sin = std.mem.zeroes(std.posix.sockaddr.in);
    if (@hasField(std.posix.sockaddr.in, "len")) {
        sin.len = @sizeOf(std.posix.sockaddr.in);
    }
    sin.family = std.posix.AF.INET;
    sin.port = 0;
    sin.addr = 0x0100007f; // 127.0.0.1

    assert(C.bind(fd, &sin, @sizeOf(std.posix.sockaddr.in)) == 0);
    assert(C.listen(fd, 1) == 0);

    var bound_len: c_uint = @sizeOf(std.posix.sockaddr.in);
    assert(C.getsockname(fd, &sin, &bound_len) == 0);
    const port = std.mem.bigToNative(u16, sin.port);

    const Context = struct {
        listen_fd: c_int,
        data: []const u8,

        fn run(ctx: @This()) void {
            defer assert(C.close(ctx.listen_fd) == 0);
            const client_fd = C.accept(ctx.listen_fd, null, null);
            if (client_fd >= 0) {
                defer assert(C.close(client_fd) == 0);
                var buf: [512]u8 = undefined;
                const read_bytes = C.read(client_fd, &buf, buf.len);
                assert(read_bytes >= 0);
                if (ctx.data.len > 0) {
                    const written_bytes = C.write(client_fd, ctx.data.ptr, ctx.data.len);
                    assert(written_bytes == @as(isize, @intCast(ctx.data.len)));
                }
            }
        }
    };

    const thread = try std.Thread.spawn(.{}, Context.run, .{
        Context{ .listen_fd = fd, .data = response_data },
    });
    return .{ .thread = thread, .port = port };
}

test "AsyncClient: send failure path c_headers leak reproduction" {
    const allocator = std.testing.allocator;
    const io = std.testing.io;

    var client = try Self.init(allocator, io, .{});
    defer client.deinit();

    const Failing = struct {
        fn hook(easy: *Easy) !void {
            _ = easy;
            return error.HookFailed;
        }
    };

    var req = client.get("http://127.0.0.1:1")
        .headers(&.{.{ .name = "X-Custom", .value = "value" }})
        .configure(Failing.hook);

    // This should fail cleanly with error.HookFailed without leaking c_headers
    const res = req.send(io);
    try std.testing.expectError(error.HookFailed, res);
}

test "AsyncClient: transfer failure does not crash on body double free (offline local)" {
    const allocator = std.testing.allocator;
    const io = std.testing.io;

    var client = try Self.init(allocator, io, .{});
    defer client.deinit();

    // Server sends chunked data and abruptly closes, leaving transfer incomplete
    const chunked_response =
        "HTTP/1.1 200 OK\r\n" ++
        "Transfer-Encoding: chunked\r\n" ++
        "Connection: close\r\n\r\n" ++
        "5\r\nhello\r\n";
    const s = try startMockServer(chunked_response);
    defer s.thread.join();

    const url = try allocator.printSentinel("http://127.0.0.1:{d}/", .{s.port}, 0);
    defer allocator.free(url);

    // Must return HttpTransferFailed WITHOUT double-free crashing on partially-written body!
    const res = client.get(url).timeout(3000).send(io);
    try std.testing.expectError(error.HttpTransferFailed, res);
}

test "AsyncClient: Response has no dangling easy_handle and pool reuse works (offline local)" {
    const allocator = std.testing.allocator;
    const io = std.testing.io;

    var client = try Self.init(allocator, io, .{});
    defer client.deinit();

    const ok_response = "HTTP/1.1 200 OK\r\nContent-Length: 2\r\nConnection: close\r\n\r\nOK";
    const s = try startMockServer(ok_response);
    defer s.thread.join();

    const url = try allocator.printSentinel("http://127.0.0.1:{d}/", .{s.port}, 0);
    defer allocator.free(url);

    var res = try client.get(url)
        .headers(&.{.{ .name = "X-Test", .value = "1" }})
        .timeout(3000)
        .send(io);
    defer res.deinit();

    // Clean handle has been returned to pool, and Response body is intact
    assert(client.pool.items.items.len == 1);
    assert(res.status_code == 200);
    assert(std.mem.eql(u8, res.body, "OK"));
}

test "AsyncClient: fluent chaining works seamlessly on rvalues" {
    const allocator = std.testing.allocator;
    const io = std.testing.io;
    var client = try Self.init(allocator, io, .{});
    defer client.deinit();

    const pong_response = "HTTP/1.1 200 OK\r\nContent-Length: 4\r\nConnection: close\r\n\r\npong";
    const s = try startMockServer(pong_response);
    defer s.thread.join();

    const url = try allocator.printSentinel("http://127.0.0.1:{d}/", .{s.port}, 0);
    defer allocator.free(url);

    // Directly chain on rvalue returned by client.post()!
    var res = try client.post(url)
        .headers(&.{.{ .name = "Content-Type", .value = "text/plain" }})
        .body("ping")
        .timeout(3000)
        .send(io);
    defer res.deinit();

    assert(res.status_code == 200);
    assert(std.mem.eql(u8, res.body, "pong"));
}

test "AsyncClient: cross-platform SockaddrIn layout verification" {
    // Verifies review.md issue #2:
    // A hardcoded macOS layout (with sin_len: u8) when interpreted on Linux
    // places 16 at byte 0 and 2 at byte 1, causing Linux sin_family (u16) to be 528 (0x0210),
    // which fails AF_INET comparison and causes bind() to fail.
    const LinuxSockaddrIn = extern struct {
        family: u16,
        port: u16,
        addr: u32,
        zero: [8]u8,
    };
    const MacSockaddrIn = extern struct {
        sin_len: u8 = 16,
        sin_family: u8 = 2,
        sin_port: u16 = 0,
        sin_addr: u32 = 0x0100007f,
        sin_zero: [8]u8 = @splat(0),
    };

    const mac_sin = MacSockaddrIn{};
    const as_linux: *const LinuxSockaddrIn = @ptrCast(&mac_sin);

    // Byte 0 is sin_len (16), Byte 1 is sin_family (2). On little-endian, Linux reads this as 528.
    try std.testing.expectEqual(@as(u16, 528), as_linux.family);
    try std.testing.expect(as_linux.family != std.posix.AF.INET);

    // Verify std.posix.sockaddr.in has valid family on current platform
    var native_sin = std.mem.zeroes(std.posix.sockaddr.in);
    if (@hasField(std.posix.sockaddr.in, "len")) {
        native_sin.len = @sizeOf(std.posix.sockaddr.in);
    }
    native_sin.family = std.posix.AF.INET;
    try std.testing.expectEqual(std.posix.AF.INET, native_sin.family);
}

test "AsyncClient: shutdown drain cleans up in-flight requests without hanging" {
    const allocator = std.testing.allocator;
    const io = std.testing.io;

    var client = try Self.init(allocator, io, .{});

    // Start a server with empty response that keeps socket open
    const s = try startMockServer("");

    const Worker = struct {
        fn run(c_ptr: *Self, i: std.Io, port: u16, err_out: *anyerror) void {
            const url = std.fmt.allocPrintSentinel(
                std.testing.allocator,
                "http://127.0.0.1:{d}/",
                .{port},
                0,
            ) catch return;
            defer std.testing.allocator.free(url);

            const res = c_ptr.get(url).timeout(30000).send(i);
            if (res) |r| {
                var mut_r = r;
                mut_r.deinit();
            } else |err| {
                err_out.* = err;
            }
        }
    };

    var observed_err: anyerror = error.NoError;
    const t = try std.Thread.spawn(.{}, Worker.run, .{ client, io, s.port, &observed_err });

    // Wait briefly so the transfer enters multi and is in-flight
    const C = struct {
        extern "c" fn usleep(usec: c_uint) c_int;
    };
    const sleep_rc = C.usleep(50_000); // 50ms
    assert(sleep_rc == 0);

    // Deinit client while transfer is still pending! Must abort cleanly without hanging.
    client.deinit();

    t.join();
    s.thread.join();

    // The transfer must have been cleanly aborted (HttpTransferFailed), NOT hung!
    try std.testing.expectEqual(error.HttpTransferFailed, observed_err);
}
