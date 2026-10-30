//! `Client` provides an asynchronous, high-throughput, structured HTTP client
//! integrating libcurl's multi-handle with `std.Io` concurrency runtime.
//!
//! ## Architecture & Thread Model
//!
//! The client adopts a decoupled, event-driven producer-consumer architecture that
//! bridges libcurl's native C networking engine with Zig's cooperative fiber runtime:
//!
//! ```text
//!                                  [ Architecture Overview ]
//!
//!   +----------------------------------------+
//!   | Caller Fibers / OS Threads (Producers) |
//!   |   - client.get(url).send(io)           |
//!   +----------------------------------------+
//!          │ (1) Acquire Easy                 │ (2) Push RequestContext
//!          ▼                                  ▼
//!   [ HandlePool ]                   [ pending_queue (SpinLock) ]
//!                                             │
//!          ┌──────────────────────────────────┘ (3) idle_event.set() & curl_multi_wakeup()
//!          │ (Wakes up driver thread instantly)
//!          ▼
//!   +--------------------------------------------------------------+
//!   | Dedicated Background Driver Thread (Consumer & Reactor)      |
//!   |                                                              |
//!   |   driverLoop()                                               |
//!   |     ├─► drainPendingQueue()  ──► curl_multi_add_handle()     |
//!   |     ├─► if idle (active==null)──► idle_event.wait() (NO timeout!)
//!   |     ├─► curl_multi_poll(1s)  ──► polls sockets (auto internal timeouts)
//!   |     ├─► curl_multi_perform() ──► drives HTTP/TLS engine      |
//!   |     └─► processDoneTransfers()                               |
//!   |             │                                                |
//!   |             └─► ctx.event.set(ctx.io) ──────────────────┐    |
//!   +---------------------------------------------------------│----+
//!                                                             │
//!          ┌──────────────────────────────────────────────────┘ (4) Awaken waiting caller
//!          ▼
//!   [ Caller Resumes ] ──► Returns Response(status, body)
//! ```
//!
//! ```text
//!                             [ Request Lifecycle Flow ]
//!
//!  Caller Fiber                        driver_thread                         OS Kernel / libcurl
//!       │                                    │                                        │
//!       │── 1. Push RequestContext ─────────►│ (Enqueues into pending_queue)          │
//!       │── 2. idle_event.set() / wakeup ───►│ (Wakes idle driver thread instantly)   │
//!       │                                    │                                        │
//!       │── 3. context.event.wait(io)        │                                        │
//!       │      (Caller Fiber Suspends)       │── 4. drainPendingQueue()               │
//!       │                                    │      curl_multi_add_handle()           │
//!       │                                    │                                        │
//!       │                                    │── 5. curl_multi_poll(dynamic_ms) ─────►│
//!       │                                    │      (Polls only when active requests) │
//!       │                                    │◄───────────────────────────────────────│
//!       │                                    │      (Socket readable / writable)      │
//!       │                                    │                                        │
//!       │                                    │── 6. curl_multi_perform()              │
//!       │                                    │      (Data transferred to buffer)      │
//!       │                                    │                                        │
//!       │◄── 7. ctx.event.set(ctx.io) ───────│ (Process CURLMSG_DONE)                 │
//!       │      (Caller Fiber Awakened)       │                                        │
//!       ▼                                    ▼                                        ▼
//!   Returns Response                    Suspends on idle_event if active_list == null
//! ```
//!
//! 1. **Client / Fiber Callers (Producers)**:
//!    - User code calls `request.send(io)` from any thread or cooperative fiber.
//!    - Acquires an `Easy` handle from the lock-free/spinlock `HandlePool`.
//!    - Prepares the stack-allocated `RequestContext` and safely appends it to the
//!      thread-safe `pending_queue` protected by `queue_mutex`.
//!    - Triggers `idle_event.set(io)` and `curl_multi_wakeup(multi)` to immediately
//!      interrupt the background driver thread whether it is sleeping or polling.
//!    - Suspends execution via `context.event.waitUncancelable(io)` without blocking
//!      the underlying OS thread, allowing other fibers to run concurrently.
//!
//! 2. **Dedicated Background Driver Thread (Consumer & Reactor)**:
//!    - A single, dedicated OS thread (`driver_thread`) runs `driverLoop` to exclusively
//!      own and manipulate the `CURLM` multi-handle, completely eliminating multi-thread
//!      locking contention on libcurl internal state machines.
//!    - **Drain Phase**: Empties `pending_queue` in batch and adds handles to `multi` via
//!      `curl_multi_add_handle`, maintaining them in an `active_list`.
//!    - **True Zero-Timeout Idle Suspension**:
//!      * When idle (`active_list == null`): Unconditionally blocks on `self.idle_event.waitUncancelable(self.io)`.
//!        It does NOT call `curl_multi_poll` and sets NO timer/timeout, achieving true 0% CPU consumption.
//!      * It is awakened instantly when new requests arrive via `idle_event.set()` or during `deinit()`.
//!      * When active: Calls `curl_multi_poll` with a 1000ms safety cap. libcurl automatically
//!        scales down this timeout internally to match any pending internal protocol deadlines.
//!    - **Execution & Dispatch Phase**: Executes `curl_multi_perform`, processes done
//!      transfers (`CURLMSG_DONE`), copies responses, and awakens waiting caller fibers
//!      across threads by signaling `ctx.event.set(ctx.io)`.
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
//! - Event-driven driver loop with zero idle CPU busy-wait
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
io: std.Io,
share: *Share,
multi: *c.CURLM,
pool: HandlePool,
running: std.atomic.Value(bool),
driver_thread: std.Thread,
options: Options,
semaphore: ?std.Io.Semaphore = null,
idle_event: std.Io.Event = .unset,

ca_bundle: ?ResizableBuffer = null,
owns_ca_bundle: bool = false,

queue_mutex: SpinLock = .{},
pending_queue: ?*StreamContext = null,
active_list: ?*StreamContext = null,

stream_mutex: SpinLock = .{},
stream_list: ?*StreamContext = null,

pub const HeaderEntry = struct {
    name: []const u8,
    value: []const u8,
};

pub const BodyReader = struct {
    stream: *StreamContext,
    interface: std.Io.Reader,
    err: ?anyerror = null,

    pub fn init(stream: *StreamContext, buffer: []u8) BodyReader {
        return .{
            .stream = stream,
            .interface = .{
                .vtable = &.{
                    .stream = streamImpl,
                    .readVec = readVec,
                },
                .buffer = buffer,
                .seek = 0,
                .end = 0,
            },
            .err = null,
        };
    }

    fn streamImpl(io_r: *std.Io.Reader, io_w: *std.Io.Writer, limit: std.Io.Limit) std.Io.Reader.StreamError!usize {
        const dest = limit.slice(try io_w.writableSliceGreedy(1));
        var data: [1][]u8 = .{dest};
        const n = try readVec(io_r, &data);
        io_w.advance(n);
        return n;
    }

    fn readVec(io_r: *std.Io.Reader, data: [][]u8) std.Io.Reader.Error!usize {
        const self: *BodyReader = @alignCast(@fieldParentPtr("interface", io_r));
        var iovecs_buffer: [8][]u8 = undefined;
        const dest_n, const data_size = try io_r.writableVector(&iovecs_buffer, data);
        const dest = iovecs_buffer[0..dest_n];
        if (dest.len == 0 or dest[0].len == 0) return 0;

        var total_read: usize = 0;
        for (dest) |buf| {
            const n = self.stream.readBytes(buf) catch |err| {
                self.err = err;
                return error.ReadFailed;
            };
            total_read += n;
            if (n < buf.len) break;
        }

        if (total_read == 0) {
            return error.EndOfStream;
        }
        if (total_read > data_size) {
            io_r.end += total_read - data_size;
            return data_size;
        }
        return total_read;
    }

    /// Read bytes directly into caller provided slice dest.
    /// Returns number of bytes read, or 0 on EOF.
    pub fn read(self: *BodyReader, dest: []u8) !usize {
        return self.stream.readBytes(dest);
    }

    /// Returns the underlying failure reason if a stream error occurred (e.g. error.Timeout).
    pub fn errorReason(self: *const BodyReader) ?anyerror {
        return self.err orelse self.stream.err;
    }

    /// Read all remaining bytes from the stream into a dynamically allocated buffer.
    pub fn readAllAlloc(self: *BodyReader, allocator: Allocator, max_size: usize) ![]u8 {
        var list: std.ArrayList(u8) = .empty;
        errdefer list.deinit(allocator);

        var buf: [4096]u8 = undefined;
        while (true) {
            const n = try self.read(&buf);
            if (n == 0) break;
            if (list.items.len + n > max_size) return error.StreamTooLong;
            try list.appendSlice(allocator, buf[0..n]);
        }
        return list.toOwnedSlice(allocator);
    }
};

pub const Response = struct {
    client: *Self,
    status_code: u16,
    stream: ?*StreamContext = null,
    semaphore_held: bool = false,
    reader_buf: [4096]u8 = undefined,

    pub fn reader(self: *Response) BodyReader {
        const stream = self.stream orelse @panic("Response used after deinit");
        return BodyReader.init(stream, &self.reader_buf);
    }

    /// Read all remaining response body bytes into memory up to `max_size`.
    /// Caller owns the returned memory and must free it with `allocator`.
    ///
    /// If the response body exceeds `max_size`, returns `error.StreamTooLong`.
    /// Note that on error, the response stream is not automatically deinitialized;
    /// the caller remains responsible for calling `res.deinit()`.
    pub fn bodyAlloc(self: *Response, allocator: Allocator, max_size: usize) ![]u8 {
        var r = self.reader();
        return r.readAllAlloc(allocator, max_size);
    }

    /// Parse response body as JSON into the specified type `T` up to `max_size`.
    /// The returned `std.json.Parsed(T)` owns the underlying memory; call `parsed.deinit()` to release.
    ///
    /// If the response body exceeds `max_size`, returns `error.StreamTooLong`.
    /// Note that on error, the response stream is not automatically deinitialized;
    /// the caller remains responsible for calling `res.deinit()`.
    pub fn json(
        self: *Response,
        comptime T: type,
        options: std.json.ParseOptions,
        max_size: usize,
    ) !std.json.Parsed(T) {
        const client_allocator = self.client.allocator;
        var parsed = std.json.Parsed(T){
            .arena = try client_allocator.create(std.heap.ArenaAllocator),
            .value = undefined,
        };
        errdefer client_allocator.destroy(parsed.arena);
        parsed.arena.* = std.heap.ArenaAllocator.init(client_allocator);
        errdefer parsed.arena.deinit();

        const arena_allocator = parsed.arena.allocator();
        const bytes = try self.bodyAlloc(arena_allocator, max_size);

        var scanner = std.json.Scanner.initCompleteInput(arena_allocator, bytes);
        defer scanner.deinit();

        parsed.value = try std.json.parseFromTokenSourceLeaky(T, arena_allocator, &scanner, options);
        return parsed;
    }

    pub fn deinit(self: *Response) void {
        const stream = self.stream orelse return;
        self.stream = null;

        const client_alive = stream.client_alive.load(.acquire);

        if (client_alive) {
            const client = self.client;
            if (self.semaphore_held) {
                if (client.semaphore) |*sem| {
                    sem.post(stream.io);
                }
                self.semaphore_held = false;
            }

            stream.mutex.lock();
            const is_done = stream.eof;
            stream.mutex.unlock();

            if (!is_done) {
                stream.aborted.store(true, .release);
                client.idle_event.set(client.io);
                _ = c.curl_multi_wakeup(client.multi);
            }
        }

        stream.releaseRef();
    }
};

pub const StreamContext = struct {
    client: *Self,
    allocator: Allocator,
    io: std.Io,
    easy: *Easy,
    result: c.CURLcode = c.CURLE_OK,
    response_code: c_long = 0,
    c_headers: ?*c.struct_curl_slist = null,

    // Multi engine queue and active list links
    next: ?*StreamContext = null,
    active_prev: ?*StreamContext = null,
    active_next: ?*StreamContext = null,

    // Client stream tracking links
    stream_prev: ?*StreamContext = null,
    stream_next: ?*StreamContext = null,

    client_alive: std.atomic.Value(bool) = std.atomic.Value(bool).init(true),
    ref_count: std.atomic.Value(u32),
    mutex: SpinLock = .{},
    header_event: std.Io.Event = .unset,
    read_event: std.Io.Event = .unset,
    headers_ready: bool = false,
    eof: bool = false,
    aborted: std.atomic.Value(bool),
    err: ?anyerror = null,
    paused: bool = false,
    unpause_requested: std.atomic.Value(bool),
    is_tainted: bool = false,
    follow_location: bool = true,

    ring_buffer: []u8,
    ring_head: usize = 0,
    ring_tail: usize = 0,
    ring_count: usize = 0,

    fn onTransferDone(self: *StreamContext, result: c.CURLcode) void {
        self.mutex.lock();
        self.result = result;

        if (!self.headers_ready) {
            self.headers_ready = true;
            self.header_event.set(self.io);
        }

        self.eof = true;
        if (result != c.CURLE_OK) {
            if (result == c.CURLE_OPERATION_TIMEDOUT) {
                self.err = error.Timeout;
            } else {
                self.err = error.HttpTransferFailed;
            }
        }
        self.read_event.set(self.io);
        self.mutex.unlock();

        self.releaseRef();
    }

    fn releaseRef(self: *StreamContext) void {
        if (self.ref_count.fetchSub(1, .acq_rel) == 1) {
            const allocator = self.allocator;
            const easy = self.easy;
            const is_tainted = self.is_tainted;
            const client_alive = self.client_alive.load(.acquire);

            if (client_alive) {
                self.client.unlinkStream(self);
            }

            if (self.c_headers) |h| {
                c.curl_slist_free_all(h);
                self.c_headers = null;
            }

            allocator.free(self.ring_buffer);

            if (client_alive and !is_tainted) {
                self.client.releaseHandle(easy, false);
            } else {
                easy.deinit();
                allocator.destroy(easy);
            }

            allocator.destroy(self);
        }
    }

    fn readBytes(self: *StreamContext, dest: []u8) !usize {
        if (dest.len == 0) return 0;

        while (true) {
            self.mutex.lock();

            if (self.ring_count > 0) {
                const to_copy = @min(dest.len, self.ring_count);
                var i: usize = 0;
                while (i < to_copy) : (i += 1) {
                    dest[i] = self.ring_buffer[(self.ring_head + i) % self.ring_buffer.len];
                }
                self.ring_head = (self.ring_head + to_copy) % self.ring_buffer.len;
                self.ring_count -= to_copy;

                if (self.paused and !self.unpause_requested.load(.acquire)) {
                    const free_space = self.ring_buffer.len - self.ring_count;
                    if (free_space >= 16384) {
                        self.unpause_requested.store(true, .release);
                        if (self.client_alive.load(.acquire)) {
                            self.client.idle_event.set(self.client.io);
                            assert(c.curl_multi_wakeup(self.client.multi) == c.CURLM_OK);
                        }
                    }
                }

                self.read_event.reset();
                self.mutex.unlock();

                return to_copy;
            }

            if (self.eof) {
                const err = self.err;
                self.mutex.unlock();
                if (err) |e| return e;
                return 0; // EOF
            }

            self.mutex.unlock();
            self.read_event.waitUncancelable(self.io);
        }
    }
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
    /// Client will automatically call util.allocCABundle(allocator, io).
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
        .io = io,
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
    self.idle_event.set(self.io);
    const wakeup_rc = c.curl_multi_wakeup(self.multi);
    assert(wakeup_rc == c.CURLM_OK);
    self.driver_thread.join();

    // Mark all active/orphaned streams so they won't touch client after destruction
    self.stream_mutex.lock();
    var curr_stream = self.stream_list;
    while (curr_stream) |stream| {
        stream.client_alive.store(false, .release);
        curr_stream = stream.stream_next;
    }
    self.stream_list = null;
    self.stream_mutex.unlock();

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

fn unlinkActive(self: *Self, stream: *StreamContext) void {
    if (stream.active_prev) |prev| {
        prev.active_next = stream.active_next;
    } else {
        self.active_list = stream.active_next;
    }
    if (stream.active_next) |next| {
        next.active_prev = stream.active_prev;
    }
    stream.active_prev = null;
    stream.active_next = null;
}

fn unlinkStream(self: *Self, stream: *StreamContext) void {
    self.stream_mutex.lock();
    defer self.stream_mutex.unlock();
    if (stream.stream_prev) |prev| {
        prev.stream_next = stream.stream_next;
    } else {
        self.stream_list = stream.stream_next;
    }
    if (stream.stream_next) |next| {
        next.stream_prev = stream.stream_prev;
    }
    stream.stream_prev = null;
    stream.stream_next = null;
}

fn abortStream(stream: *StreamContext) void {
    _ = c.curl_easy_setopt(stream.easy.handle, c.CURLOPT_SHARE, @as(?*anyopaque, null));
    stream.result = c.CURLE_ABORTED_BY_CALLBACK;
    if (stream.c_headers) |h| {
        c.curl_slist_free_all(h);
        stream.c_headers = null;
    }
    stream.client_alive.store(false, .release);
    stream.is_tainted = true;
    stream.onTransferDone(stream.result);
}

fn maintainActiveStreams(self: *Self) void {
    var curr = self.active_list;
    while (curr) |stream| {
        const next = stream.active_next;
        if (stream.aborted.load(.acquire)) {
            self.unlinkActive(stream);
            assert(c.curl_multi_remove_handle(self.multi, stream.easy.handle) == c.CURLM_OK);
            if (stream.c_headers) |h| {
                c.curl_slist_free_all(h);
                stream.c_headers = null;
            }

            stream.mutex.lock();
            stream.eof = true;
            stream.read_event.set(stream.io);
            stream.mutex.unlock();

            stream.releaseRef();
        } else if (stream.unpause_requested.load(.acquire)) {
            stream.unpause_requested.store(false, .release);
            // curl_easy_pause may synchronously flush internal buffers and re-enter streamWriteCallback,
            // so it must be executed WITHOUT holding stream.mutex to prevent recursive SpinLock deadlock.
            stream.mutex.lock();
            const was_paused = stream.paused;
            stream.paused = false;
            stream.mutex.unlock();
            if (was_paused) {
                const rc = c.curl_easy_pause(stream.easy.handle, c.CURLPAUSE_CONT);
                assert(rc == c.CURLE_OK);
            }
        }
        curr = next;
    }
}

fn streamHeaderCallback(
    ptr: [*c]c_char,
    size: c_uint,
    nmemb: c_uint,
    user_data: ?*anyopaque,
) callconv(.c) c_uint {
    const total_bytes: usize = @as(usize, size) * @as(usize, nmemb);
    if (total_bytes == 0) return 0;
    const stream: *StreamContext = @ptrCast(@alignCast(user_data.?));

    const bytes: [*]const u8 = @ptrCast(ptr);
    const line = bytes[0..total_bytes];

    if ((line.len == 2 and line[0] == '\r' and line[1] == '\n') or
        (line.len == 1 and line[0] == '\n'))
    {
        var code: c_long = 0;
        _ = c.curl_easy_getinfo(stream.easy.handle, c.CURLINFO_RESPONSE_CODE, &code);

        const is_redirect = (code >= 300 and code < 400 and stream.follow_location);
        const is_informational = (code >= 100 and code < 200);

        if (!is_redirect and !is_informational) {
            stream.mutex.lock();
            if (!stream.headers_ready) {
                stream.response_code = code;
                stream.headers_ready = true;
                stream.header_event.set(stream.io);
            }
            stream.mutex.unlock();
        }
    }

    return @intCast(total_bytes);
}

fn streamWriteCallback(
    ptr: [*c]c_char,
    size: c_uint,
    nmemb: c_uint,
    user_data: ?*anyopaque,
) callconv(.c) c_uint {
    const total_bytes: usize = @as(usize, size) * @as(usize, nmemb);
    if (total_bytes == 0) return 0;
    const stream: *StreamContext = @ptrCast(@alignCast(user_data.?));

    stream.mutex.lock();

    if (!stream.headers_ready) {
        var code: c_long = 0;
        _ = c.curl_easy_getinfo(stream.easy.handle, c.CURLINFO_RESPONSE_CODE, &code);
        stream.response_code = code;
        stream.headers_ready = true;
        stream.header_event.set(stream.io);
    }

    if (stream.aborted.load(.acquire)) {
        stream.mutex.unlock();
        return @intCast(c.CURL_WRITEFUNC_PAUSE);
    }

    const available = stream.ring_buffer.len - stream.ring_count;
    if (available < total_bytes) {
        stream.paused = true;
        stream.mutex.unlock();
        return @intCast(c.CURL_WRITEFUNC_PAUSE);
    }

    const bytes: [*]const u8 = @ptrCast(ptr);
    var i: usize = 0;
    while (i < total_bytes) : (i += 1) {
        stream.ring_buffer[(stream.ring_tail + i) % stream.ring_buffer.len] = bytes[i];
    }
    stream.ring_tail = (stream.ring_tail + total_bytes) % stream.ring_buffer.len;
    stream.ring_count += total_bytes;

    stream.read_event.set(stream.io);
    stream.mutex.unlock();

    return @intCast(total_bytes);
}

fn driverLoop(self: *Self) void {
    while (self.running.load(.acquire)) {
        self.drainPendingQueue();
        self.maintainActiveStreams();

        if (self.active_list == null) {
            // Idle state: no active network transfers in flight.
            // Suspend unconditionally on `idle_event` without calling curl_multi_poll,
            // achieving true event-driven suspension with ZERO CPU usage and NO timeout!
            self.idle_event.waitUncancelable(self.io);
            self.idle_event.reset();
            continue;
        }

        // Active transfers in flight: poll for socket activity.
        // Per `man curl_multi_poll`, libcurl automatically scales down the 1000ms cap
        // if internal timers (e.g. DNS resolution, connect timeout) expire earlier.
        var num_fds: c_int = 0;
        const poll_rc = c.curl_multi_poll(self.multi, null, 0, 1000, &num_fds);
        assert(poll_rc == c.CURLM_OK);

        self.maintainActiveStreams();

        var still_running: c_int = 0;
        const perform_rc = c.curl_multi_perform(self.multi, &still_running);
        assert(perform_rc == c.CURLM_OK);

        self.processDoneTransfers();
    }

    // Drain remaining transfers on shutdown with bounded iterations (max ~5s)
    self.drainPendingQueue();
    self.maintainActiveStreams();
    var still_running: c_int = 1;
    var drain_iters: usize = 0;
    while (still_running > 0 and drain_iters < 100) : (drain_iters += 1) {
        self.maintainActiveStreams();
        const drain_perform_rc = c.curl_multi_perform(self.multi, &still_running);
        assert(drain_perform_rc == c.CURLM_OK);
        self.processDoneTransfers();
        var num_fds: c_int = 0;
        const drain_poll_rc = c.curl_multi_poll(self.multi, null, 0, 50, &num_fds);
        assert(drain_poll_rc == c.CURLM_OK);
    }

    // If any active transfers remain in multi after shutdown drain, abort and remove them
    var curr_active = self.active_list;
    while (curr_active) |stream| {
        const next = stream.active_next;
        assert(c.curl_multi_remove_handle(self.multi, stream.easy.handle) == c.CURLM_OK);
        abortStream(stream);
        curr_active = next;
    }
    self.active_list = null;

    // Also cancel any unhandled items left in pending_queue
    self.queue_mutex.lock();
    var unhandled = self.pending_queue;
    self.pending_queue = null;
    self.queue_mutex.unlock();
    while (unhandled) |stream| {
        const next = stream.next;
        abortStream(stream);
        unhandled = next;
    }
}

fn drainPendingQueue(self: *Self) void {
    self.queue_mutex.lock();
    var item = self.pending_queue;
    self.pending_queue = null;
    self.queue_mutex.unlock();

    while (item) |stream| {
        const next = stream.next;
        const rc = c.curl_multi_add_handle(self.multi, stream.easy.handle);
        if (rc != c.CURLM_OK) {
            stream.result = c.CURLE_FAILED_INIT;
            if (stream.c_headers) |h| {
                c.curl_slist_free_all(h);
                stream.c_headers = null;
            }
            stream.onTransferDone(stream.result);
        } else {
            stream.active_next = self.active_list;
            stream.active_prev = null;
            if (self.active_list) |active_head| {
                active_head.active_prev = stream;
            }
            self.active_list = stream;
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
                const stream: *StreamContext = @ptrCast(@alignCast(ptr));
                self.unlinkActive(stream);

                stream.result = msg.*.data.result;

                var code: c_long = 0;
                const resp_rc = c.curl_easy_getinfo(
                    easy_handle,
                    c.CURLINFO_RESPONSE_CODE,
                    &code,
                );
                assert(resp_rc == c.CURLE_OK);
                stream.response_code = code;

                const remove_rc = c.curl_multi_remove_handle(self.multi, easy_handle);
                assert(remove_rc == c.CURLM_OK);

                if (stream.c_headers) |h| {
                    c.curl_slist_free_all(h);
                    stream.c_headers = null;
                }

                _ = c.curl_easy_setopt(easy_handle, c.CURLOPT_SHARE, @as(?*anyopaque, null));
                stream.onTransferDone(stream.result);
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

    /// Send the HTTP request asynchronously and return a `Response` as soon as headers are received.
    /// The response body can be read incrementally via `res.reader()` or fully buffered via `res.bodyAlloc()`.
    ///
    /// Lifetime contract: The returned `Response` must be closed (via `res.deinit()`)
    /// before `client.deinit()` is called, as the active stream borrows internal resources (easy handle,
    /// connection share context, and semaphore permits) from the `Client`.
    pub fn send(self: RequestBuilder, io: std.Io) !Response {
        const client = self.client;

        if (client.semaphore) |*sem| {
            try sem.wait(io);
        }
        var sem_released = false;
        errdefer if (client.semaphore) |*sem| {
            if (!sem_released) sem.post(io);
        };

        const easy = if (self.is_tainted)
            try client.createFreshHandle()
        else
            try client.acquireHandle();

        var easy_released = false;
        errdefer if (!easy_released) client.releaseHandle(easy, self.is_tainted);

        var stream_released = false;
        const stream = try client.allocator.create(StreamContext);
        errdefer if (!stream_released) client.allocator.destroy(stream);

        const ring_buffer = try client.allocator.alloc(u8, 64 * 1024);
        errdefer if (!stream_released) client.allocator.free(ring_buffer);

        stream.* = .{
            .client = client,
            .allocator = client.allocator,
            .io = io,
            .easy = easy,
            .ref_count = std.atomic.Value(u32).init(2),
            .is_tainted = self.is_tainted,
            .follow_location = self.follow_location,
            .ring_buffer = ring_buffer,
            .aborted = std.atomic.Value(bool).init(false),
            .unpause_requested = std.atomic.Value(bool).init(false),
        };

        try easy.setUrl(self.url);
        try easy.setMethod(self.method);
        if (self.method == .HEAD) {
            try checkCode(
                c.curl_easy_setopt(easy.handle, c.CURLOPT_NOBODY, @as(c_long, 1)),
                &easy.diagnostics,
            );
        }
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

        // Custom headers
        const ch = try buildHeaderSlist(client.allocator, self.custom_headers);
        stream.c_headers = ch;
        errdefer if (!stream_released) {
            if (stream.c_headers) |h| {
                c.curl_slist_free_all(h);
                stream.c_headers = null;
            }
        };
        if (ch) |headers_list| {
            try easy.setHeadersC(headers_list);
        }

        try easy.setCommonOpts();

        if (self.config_hook) |hook| {
            try hook(easy);
        }

        try checkCode(c.curl_easy_setopt(easy.handle, c.CURLOPT_WRITEFUNCTION, streamWriteCallback), &easy.diagnostics);
        try checkCode(c.curl_easy_setopt(easy.handle, c.CURLOPT_WRITEDATA, stream), &easy.diagnostics);
        try checkCode(c.curl_easy_setopt(easy.handle, c.CURLOPT_HEADERFUNCTION, streamHeaderCallback), &easy.diagnostics);
        try checkCode(c.curl_easy_setopt(easy.handle, c.CURLOPT_HEADERDATA, stream), &easy.diagnostics);

        try easy.setPrivate(stream);

        // Register stream in client's active stream tracking list
        {
            client.stream_mutex.lock();
            stream.stream_next = client.stream_list;
            stream.stream_prev = null;
            if (client.stream_list) |s_head| {
                s_head.stream_prev = stream;
            }
            client.stream_list = stream;
            client.stream_mutex.unlock();
        }

        // Enqueue to pending queue and wake driver
        {
            client.queue_mutex.lock();
            stream.next = client.pending_queue;
            client.pending_queue = stream;
            client.queue_mutex.unlock();
        }

        client.idle_event.set(client.io);
        const wakeup_rc = c.curl_multi_wakeup(client.multi);
        assert(wakeup_rc == c.CURLM_OK);

        // Wait until headers are received or transfer fails
        stream.header_event.waitUncancelable(io);

        if (stream.result != c.CURLE_OK) {
            const result = stream.result;
            stream_released = true;
            easy_released = true;
            stream.releaseRef();
            if (client.semaphore) |*sem| {
                sem.post(io);
                sem_released = true;
            }
            if (result == c.CURLE_OPERATION_TIMEDOUT) {
                return error.Timeout;
            }
            return error.HttpTransferFailed;
        }

        stream_released = true;
        return Response{
            .client = client,
            .status_code = @intCast(stream.response_code),
            .stream = stream,
            .semaphore_held = client.semaphore != null,
        };
    }
};

fn buildHeaderSlist(allocator: Allocator, entries: []const HeaderEntry) !?*c.struct_curl_slist {
    if (entries.len == 0) return null;
    var ch: ?*c.struct_curl_slist = null;
    errdefer if (ch) |h| c.curl_slist_free_all(h);
    for (entries) |h| {
        const line = try allocator.printSentinel("{s}: {s}", .{ h.name, h.value }, 0);
        defer allocator.free(line);
        ch = c.curl_slist_append(ch, line.ptr) orelse return error.OutOfMemory;
    }
    return ch;
}

// -------------------------------------------------------------------------
// Unit Tests
// -------------------------------------------------------------------------

test "Client: init and deinit lifecycle" {
    // Verifies that Client and its background worker thread can be started
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

test "Client: handle pool reuse and taint isolation" {
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

test "Client: RequestBuilder configuration chaining" {
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

test "Client: max_concurrency semaphore integration" {
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

test "Client: uncancelable event wait safety" {
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

fn startMockServer(
    io: std.Io,
    response_data: []const u8,
) !struct { thread: std.Thread, port: u16 } {
    const addr = std.Io.net.IpAddress{ .ip4 = std.Io.net.Ip4Address.loopback(0) };
    var server = try addr.listen(io, .{ .mode = .stream });
    const port = server.socket.address.getPort();

    const Context = struct {
        server: std.Io.net.Server,
        io: std.Io,
        data: []const u8,

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

            if (std.mem.startsWith(u8, ctx.data, "HTTP/1.")) {
                writer.interface.writeAll(ctx.data) catch return;
                writer.interface.flush() catch return;
            } else {
                req.respond(ctx.data, .{ .status = .ok, .keep_alive = false }) catch return;
            }
        }
    };

    const thread = try std.Thread.spawn(.{}, Context.run, .{Context{
        .server = server,
        .io = io,
        .data = response_data,
    }});
    return .{ .thread = thread, .port = port };
}

test "Client: send failure path c_headers leak reproduction" {
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

test "Client: transfer failure does not crash on body double free (offline local)" {
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
    const s = try startMockServer(io, chunked_response);
    defer s.thread.join();

    const url = try allocator.printSentinel("http://127.0.0.1:{d}/", .{s.port}, 0);
    defer allocator.free(url);

    // In unified streaming model, send() succeeds as soon as 200 OK headers arrive,
    // and transfer failure is safely reported during body read without double-free/leak.
    var res = try client.get(url).timeout(3000).send(io);
    defer res.deinit();
    try std.testing.expectEqual(@as(u16, 200), res.status_code);

    const body_res = res.bodyAlloc(allocator, 1024);
    try std.testing.expectError(error.HttpTransferFailed, body_res);
}

test "Client: Response has no dangling easy_handle and pool reuse works (offline local)" {
    const allocator = std.testing.allocator;
    const io = std.testing.io;

    var client = try Self.init(allocator, io, .{});
    defer client.deinit();

    const s = try startMockServer(io, "OK");
    defer s.thread.join();

    const url = try allocator.printSentinel("http://127.0.0.1:{d}/", .{s.port}, 0);
    defer allocator.free(url);

    var res = try client.get(url)
        .headers(&.{.{ .name = "X-Test", .value = "1" }})
        .timeout(3000)
        .send(io);

    assert(res.status_code == 200);
    const body = try res.bodyAlloc(allocator, 1024);
    defer allocator.free(body);
    assert(std.mem.eql(u8, body, "OK"));

    res.deinit();
    // Clean handle has been returned to pool after res.deinit()
    assert(client.pool.items.items.len == 1);
}

test "Client: fluent chaining works seamlessly on rvalues" {
    const allocator = std.testing.allocator;
    const io = std.testing.io;
    var client = try Self.init(allocator, io, .{});
    defer client.deinit();

    const s = try startMockServer(io, "pong");
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
    const body = try res.bodyAlloc(allocator, 1024);
    defer allocator.free(body);
    assert(std.mem.eql(u8, body, "pong"));
}

test "Client: HEAD request completes without waiting for body" {
    const allocator = std.testing.allocator;
    const io = std.testing.io;

    const s = try startMockServer(io, "OK");
    defer s.thread.join();

    var client = try Self.init(allocator, io, .{ .load_ca_bundle = false });
    defer client.deinit();

    const url = try allocator.printSentinel("http://127.0.0.1:{d}/", .{s.port}, 0);
    defer allocator.free(url);

    var res = try client.head(url).timeout(3000).send(io);
    defer res.deinit();

    try std.testing.expectEqual(@as(u16, 200), res.status_code);
    const body = try res.bodyAlloc(allocator, 1024);
    defer allocator.free(body);
    try std.testing.expectEqual(@as(usize, 0), body.len);
}

test "Client: shutdown drain cleans up in-flight requests without hanging" {
    const allocator = std.testing.allocator;
    const io = std.testing.io;

    var client = try Self.init(allocator, io, .{ .load_ca_bundle = false });
    defer client.deinit();

    const s = try startMockServer(io, "OK");
    defer s.thread.join();

    const url = try allocator.printSentinel("http://127.0.0.1:{d}/", .{s.port}, 0);
    defer allocator.free(url);

    var res = try client.get(url).timeout(3000).send(io);
    defer res.deinit();

    try std.testing.expectEqual(@as(u16, 200), res.status_code);
}

test "Client: send reads entire body via reader" {
    const allocator = std.testing.allocator;
    const io = std.testing.io;

    const payload = "Hello, streaming world! This is a test chunked response.";
    const s = try startMockServer(io, payload);
    defer s.thread.join();

    var client = try Self.init(allocator, io, .{ .load_ca_bundle = false });
    defer client.deinit();

    const url = try allocator.printSentinel("http://127.0.0.1:{d}/", .{s.port}, 0);
    defer allocator.free(url);

    var res = try client.get(url).timeout(3000).send(io);
    defer res.deinit();

    try std.testing.expectEqual(@as(u16, 200), res.status_code);

    var reader = res.reader();
    const body = try reader.readAllAlloc(allocator, 1024 * 1024);
    defer allocator.free(body);

    try std.testing.expectEqualStrings(payload, body);
}

test "Client: send integrates with std.Io.Reader line delimiter" {
    const allocator = std.testing.allocator;
    const io = std.testing.io;

    const payload = "line1\nline2\nline3\n";
    const s = try startMockServer(io, payload);
    defer s.thread.join();

    var client = try Self.init(allocator, io, .{ .load_ca_bundle = false });
    defer client.deinit();

    const url = try allocator.printSentinel("http://127.0.0.1:{d}/", .{s.port}, 0);
    defer allocator.free(url);

    var res = try client.get(url).timeout(3000).send(io);
    defer res.deinit();

    try std.testing.expectEqual(@as(u16, 200), res.status_code);

    var reader = res.reader();
    const l1 = (try reader.interface.takeDelimiter('\n')).?;
    try std.testing.expectEqualStrings("line1", l1);
    const l2 = (try reader.interface.takeDelimiter('\n')).?;
    try std.testing.expectEqualStrings("line2", l2);
    const l3 = (try reader.interface.takeDelimiter('\n')).?;
    try std.testing.expectEqualStrings("line3", l3);
}

test "Client: send early deinit cancels in-flight transfer without leak" {
    const allocator = std.testing.allocator;
    const io = std.testing.io;

    const payload = "Some data that we only partially read";
    const s = try startMockServer(io, payload);
    defer s.thread.join();

    var client = try Self.init(allocator, io, .{ .load_ca_bundle = false });
    defer client.deinit();

    const url = try allocator.printSentinel("http://127.0.0.1:{d}/", .{s.port}, 0);
    defer allocator.free(url);

    var res = try client.get(url).timeout(3000).send(io);
    var reader = res.reader();
    var small_buf: [4]u8 = undefined;
    const n = try reader.read(&small_buf);
    try std.testing.expect(n > 0);

    // Drop res early while transfer is still active on server/driver
    res.deinit();
}

fn startStreamingBytesServer(
    io: std.Io,
    total_bytes: usize,
    chunk_byte: u8,
) !struct { thread: std.Thread, port: u16 } {
    const addr = std.Io.net.IpAddress{ .ip4 = std.Io.net.Ip4Address.loopback(0) };
    var server = try addr.listen(io, .{ .mode = .stream });
    const port = server.socket.address.getPort();

    const Context = struct {
        server: std.Io.net.Server,
        io: std.Io,
        total: usize,
        byte: u8,

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
            _ = http_server.receiveHead() catch return;

            var hdr_buf: [128]u8 = undefined;
            const header = std.fmt.bufPrint(&hdr_buf, "HTTP/1.1 200 OK\r\nContent-Length: {d}\r\nConnection: close\r\n\r\n", .{ctx.total}) catch return;
            writer.interface.writeAll(header) catch return;
            writer.interface.flush() catch return;

            var chunk: [16 * 1024]u8 = undefined;
            @memset(&chunk, ctx.byte);
            var remaining = ctx.total;
            while (remaining > 0) {
                const to_write = @min(remaining, chunk.len);
                writer.interface.writeAll(chunk[0..to_write]) catch return;
                writer.interface.flush() catch return;
                remaining -= to_write;
            }
        }
    };

    const thread = try std.Thread.spawn(.{}, Context.run, .{Context{
        .server = server,
        .io = io,
        .total = total_bytes,
        .byte = chunk_byte,
    }});
    return .{ .thread = thread, .port = port };
}

fn startStallMockServer(
    io: std.Io,
) !struct { thread: std.Thread, port: u16 } {
    const addr = std.Io.net.IpAddress{ .ip4 = std.Io.net.Ip4Address.loopback(0) };
    var server = try addr.listen(io, .{ .mode = .stream });
    const port = server.socket.address.getPort();

    const Context = struct {
        server: std.Io.net.Server,
        io: std.Io,

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
            _ = http_server.receiveHead() catch return;

            const response_chunk = "HTTP/1.1 200 OK\r\nTransfer-Encoding: chunked\r\nConnection: close\r\n\r\n5\r\nchunk\r\n";
            writer.interface.writeAll(response_chunk) catch return;
            writer.interface.flush() catch return;

            // Stall by sleeping for 1500ms
            std.Io.sleep(ctx.io, std.Io.Duration.fromMilliseconds(1500), .awake) catch {};
        }
    };

    const thread = try std.Thread.spawn(.{}, Context.run, .{Context{
        .server = server,
        .io = io,
    }});
    return .{ .thread = thread, .port = port };
}

test "Client: send 1MiB body backpressure and unpause without deadlock" {
    const allocator = std.testing.allocator;
    const io = std.testing.io;

    const total_expected = 1024 * 1024;
    const s = try startStreamingBytesServer(io, total_expected, 'M');
    defer s.thread.join();

    var client = try Self.init(allocator, io, .{ .load_ca_bundle = false });
    defer client.deinit();

    const url = try allocator.printSentinel("http://127.0.0.1:{d}/", .{s.port}, 0);
    defer allocator.free(url);

    var res = try client.get(url).timeout(5000).send(io);
    defer res.deinit();

    try std.testing.expectEqual(@as(u16, 200), res.status_code);

    var reader = res.reader();
    var chunk_buf: [16 * 1024]u8 = undefined;
    var total_received: usize = 0;

    while (true) {
        const n = try reader.read(&chunk_buf);
        if (n == 0) break;
        for (chunk_buf[0..n]) |b| {
            if (b != 'M') return error.UnexpectedByte;
        }
        total_received += n;
    }

    try std.testing.expectEqual(total_expected, total_received);
    try std.testing.expect(reader.errorReason() == null);
}

test "Client: send dual concurrent streams backpressure" {
    const allocator = std.testing.allocator;
    const io = std.testing.io;

    const s1_size = 512 * 1024;
    const s2_size = 256 * 1024;

    const s1 = try startStreamingBytesServer(io, s1_size, 'A');
    defer s1.thread.join();
    const s2 = try startStreamingBytesServer(io, s2_size, 'B');
    defer s2.thread.join();

    var client = try Self.init(allocator, io, .{ .load_ca_bundle = false });
    defer client.deinit();

    const url1 = try allocator.printSentinel("http://127.0.0.1:{d}/", .{s1.port}, 0);
    defer allocator.free(url1);
    const url2 = try allocator.printSentinel("http://127.0.0.1:{d}/", .{s2.port}, 0);
    defer allocator.free(url2);

    var res1 = try client.get(url1).timeout(5000).send(io);
    defer res1.deinit();
    var res2 = try client.get(url2).timeout(5000).send(io);
    defer res2.deinit();

    var r1 = res1.reader();
    var r2 = res2.reader();

    var buf: [8192]u8 = undefined;
    var n1_total: usize = 0;
    var n2_total: usize = 0;
    var done1 = false;
    var done2 = false;

    while (!done1 or !done2) {
        if (!done1) {
            const n = try r1.read(&buf);
            if (n == 0) {
                done1 = true;
            } else {
                for (buf[0..n]) |b| {
                    if (b != 'A') return error.UnexpectedByte;
                }
                n1_total += n;
            }
        }
        if (!done2) {
            const n = try r2.read(&buf);
            if (n == 0) {
                done2 = true;
            } else {
                for (buf[0..n]) |b| {
                    if (b != 'B') return error.UnexpectedByte;
                }
                n2_total += n;
            }
        }
    }

    try std.testing.expectEqual(s1_size, n1_total);
    try std.testing.expectEqual(s2_size, n2_total);
}

test "Client: send 1MiB early abort without memory leak" {
    const allocator = std.testing.allocator;
    const io = std.testing.io;

    const s = try startStreamingBytesServer(io, 1024 * 1024, 'K');
    defer s.thread.join();

    var client = try Self.init(allocator, io, .{ .load_ca_bundle = false });
    defer client.deinit();

    const url = try allocator.printSentinel("http://127.0.0.1:{d}/", .{s.port}, 0);
    defer allocator.free(url);

    var res = try client.get(url).timeout(5000).send(io);
    var reader = res.reader();

    var small_buf: [4096]u8 = undefined;
    const n = try reader.read(&small_buf);
    try std.testing.expect(n > 0);

    // Abort early while transfer is still active on server/driver
    res.deinit();
}

test "Client: send stall timeout detection" {
    const allocator = std.testing.allocator;
    const io = std.testing.io;

    const s = try startStallMockServer(io);
    defer s.thread.join();

    var client = try Self.init(allocator, io, .{ .load_ca_bundle = false });
    defer client.deinit();

    const url = try allocator.printSentinel("http://127.0.0.1:{d}/", .{s.port}, 0);
    defer allocator.free(url);

    var res = try client.get(url).timeout(400).send(io);
    defer res.deinit();

    try std.testing.expectEqual(@as(u16, 200), res.status_code);

    var reader = res.reader();
    var buf: [128]u8 = undefined;

    // First chunk ("chunk") should succeed
    const n1 = try reader.read(&buf);
    try std.testing.expectEqual(@as(usize, 5), n1);
    try std.testing.expectEqualStrings("chunk", buf[0..n1]);

    // Second read should encounter timeout due to stall
    const read_res = reader.read(&buf);
    try std.testing.expectError(error.Timeout, read_res);
    try std.testing.expectEqual(error.Timeout, reader.errorReason().?);
}

test "Client: client.deinit() cross-destruction with active Response does not panic" {
    const allocator = std.testing.allocator;
    const io = std.testing.io;

    const s = try startStreamingBytesServer(io, 1024 * 1024, 'Z');
    defer s.thread.join();

    var client = try Self.init(allocator, io, .{ .load_ca_bundle = false });

    const url = try allocator.printSentinel("http://127.0.0.1:{d}/", .{s.port}, 0);
    defer allocator.free(url);

    var res = try client.get(url).timeout(5000).send(io);

    // Destroy client while Response is still alive and streaming
    client.deinit();

    // Subsequent read on the orphaned stream must return error and not crash
    var buf: [32]u8 = undefined;
    var reader = res.reader();
    _ = reader.read(&buf) catch {};

    // res.deinit() must clean up without panic or use-after-free
    res.deinit();
}

test "Client: send connect refused fails cleanly without UAF or double-free" {
    const allocator = std.testing.allocator;
    const io = std.testing.io;

    var client = try Self.init(allocator, io, .{ .load_ca_bundle = false });
    defer client.deinit();

    // 127.0.0.1:1 is guaranteed connection refused
    const res = client.get("http://127.0.0.1:1/")
        .headers(&.{.{ .name = "X-Test", .value = "UAF-Check" }})
        .timeout(1000)
        .send(io);

    try std.testing.expectError(error.HttpTransferFailed, res);
}

test "Client: send DNS failure fails cleanly without UAF or double-free" {
    const allocator = std.testing.allocator;
    const io = std.testing.io;

    var client = try Self.init(allocator, io, .{ .load_ca_bundle = false });
    defer client.deinit();

    const res = client.get("http://invalid.domain.that.does.not.exist.test/")
        .headers(&.{.{ .name = "X-Test", .value = "DNS-Check" }})
        .timeout(1000)
        .send(io);

    try std.testing.expectError(error.HttpTransferFailed, res);
}

fn startEmptyBodyServer(io: std.Io) !struct { thread: std.Thread, port: u16 } {
    const addr = std.Io.net.IpAddress{ .ip4 = std.Io.net.Ip4Address.loopback(0) };
    var server = try addr.listen(io, .{ .mode = .stream });
    const port = server.socket.address.getPort();

    const Context = struct {
        server: std.Io.net.Server,
        io: std.Io,

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
            req.respond("", .{ .status = .ok, .keep_alive = false }) catch return;
        }
    };

    const thread = try std.Thread.spawn(.{}, Context.run, .{Context{
        .server = server,
        .io = io,
    }});
    return .{ .thread = thread, .port = port };
}

fn startMultiRequestServer(io: std.Io, total_requests: usize) !struct { thread: std.Thread, port: u16 } {
    const addr = std.Io.net.IpAddress{ .ip4 = std.Io.net.Ip4Address.loopback(0) };
    var server = try addr.listen(io, .{ .mode = .stream });
    const port = server.socket.address.getPort();

    const Context = struct {
        server: std.Io.net.Server,
        io: std.Io,
        count: usize,

        fn run(ctx: @This()) void {
            var s = ctx.server;
            defer s.deinit(ctx.io);

            var i: usize = 0;
            while (i < ctx.count) : (i += 1) {
                const stream = s.accept(ctx.io) catch return;
                var read_buf: [4096]u8 = undefined;
                var reader = std.Io.net.Stream.Reader.init(stream, ctx.io, &read_buf);
                var write_buf: [4096]u8 = undefined;
                var writer = std.Io.net.Stream.Writer.init(stream, ctx.io, &write_buf);

                var http_server = std.http.Server.init(&reader.interface, &writer.interface);
                var req = http_server.receiveHead() catch {
                    stream.close(ctx.io);
                    return;
                };
                req.respond("pong", .{ .status = .ok, .keep_alive = false }) catch {};
                stream.close(ctx.io);
            }
        }
    };

    const thread = try std.Thread.spawn(.{}, Context.run, .{Context{
        .server = server,
        .io = io,
        .count = total_requests,
    }});
    return .{ .thread = thread, .port = port };
}

fn startRedirectLoopServer(io: std.Io, max_cycles: usize) !struct { thread: std.Thread, port: u16 } {
    const addr = std.Io.net.IpAddress{ .ip4 = std.Io.net.Ip4Address.loopback(0) };
    var server = try addr.listen(io, .{ .mode = .stream });
    const port = server.socket.address.getPort();

    const Context = struct {
        server: std.Io.net.Server,
        io: std.Io,
        cycles: usize,

        fn run(ctx: @This()) void {
            var s = ctx.server;
            defer s.deinit(ctx.io);

            var i: usize = 0;
            while (i < ctx.cycles) : (i += 1) {
                const stream = s.accept(ctx.io) catch return;
                var read_buf: [4096]u8 = undefined;
                var reader = std.Io.net.Stream.Reader.init(stream, ctx.io, &read_buf);
                var write_buf: [4096]u8 = undefined;
                var writer = std.Io.net.Stream.Writer.init(stream, ctx.io, &write_buf);

                var http_server = std.http.Server.init(&reader.interface, &writer.interface);
                _ = http_server.receiveHead() catch {
                    stream.close(ctx.io);
                    return;
                };

                const redirect_resp = "HTTP/1.1 302 Found\r\nLocation: /loop\r\nContent-Length: 0\r\nConnection: close\r\n\r\n";
                writer.interface.writeAll(redirect_resp) catch {};
                writer.interface.flush() catch {};
                stream.close(ctx.io);
            }
        }
    };

    const thread = try std.Thread.spawn(.{}, Context.run, .{Context{
        .server = server,
        .io = io,
        .cycles = max_cycles,
    }});
    return .{ .thread = thread, .port = port };
}

test "Client: send 0-byte empty body returns EOF immediately" {
    const allocator = std.testing.allocator;
    const io = std.testing.io;

    const s = try startEmptyBodyServer(io);
    defer s.thread.join();

    var client = try Self.init(allocator, io, .{ .load_ca_bundle = false });
    defer client.deinit();

    const url = try allocator.printSentinel("http://127.0.0.1:{d}/", .{s.port}, 0);
    defer allocator.free(url);

    var res = try client.get(url).timeout(3000).send(io);
    defer res.deinit();

    try std.testing.expectEqual(@as(u16, 200), res.status_code);

    var reader = res.reader();
    var buf: [16]u8 = undefined;
    const n1 = try reader.read(&buf);
    try std.testing.expectEqual(@as(usize, 0), n1);

    const n2 = try reader.read(&buf);
    try std.testing.expectEqual(@as(usize, 0), n2);
    try std.testing.expect(reader.errorReason() == null);
}

test "Client: send trickle read 1 byte per iteration with backpressure" {
    const allocator = std.testing.allocator;
    const io = std.testing.io;

    const total_bytes = 70 * 1024;
    const s = try startStreamingBytesServer(io, total_bytes, 'T');
    defer s.thread.join();

    var client = try Self.init(allocator, io, .{ .load_ca_bundle = false });
    defer client.deinit();

    const url = try allocator.printSentinel("http://127.0.0.1:{d}/", .{s.port}, 0);
    defer allocator.free(url);

    var res = try client.get(url).timeout(5000).send(io);
    defer res.deinit();

    try std.testing.expectEqual(@as(u16, 200), res.status_code);

    var reader = res.reader();
    var buf: [1]u8 = undefined;
    var total_received: usize = 0;

    while (true) {
        const n = try reader.read(&buf);
        if (n == 0) break;
        try std.testing.expectEqual('T', buf[0]);
        total_received += n;
    }

    try std.testing.expectEqual(total_bytes, total_received);
    try std.testing.expect(reader.errorReason() == null);
}

test "Client: send max_concurrency semaphore acquisition and release" {
    const allocator = std.testing.allocator;
    const io = std.testing.io;

    // Server expects 2 requests
    const s = try startMultiRequestServer(io, 2);
    defer s.thread.join();

    var client = try Self.init(allocator, io, .{
        .max_concurrency = 2,
        .load_ca_bundle = false,
    });
    defer client.deinit();

    const url = try allocator.printSentinel("http://127.0.0.1:{d}/", .{s.port}, 0);
    defer allocator.free(url);

    // Initial permits: 2
    try std.testing.expectEqual(@as(usize, 2), client.semaphore.?.permits);

    // Stream 1 acquires 1 permit -> 1 left
    var res1 = try client.get(url).timeout(3000).send(io);
    try std.testing.expectEqual(@as(usize, 1), client.semaphore.?.permits);

    // Stream 2 acquires 1 permit -> 0 left (exhausted)
    var res2 = try client.get(url).timeout(3000).send(io);
    try std.testing.expectEqual(@as(usize, 0), client.semaphore.?.permits);

    // Deinit stream 1: releases 1 permit back to semaphore
    res1.deinit();
    try std.testing.expectEqual(@as(usize, 1), client.semaphore.?.permits);

    // Deinit stream 2: releases second permit back
    res2.deinit();
    try std.testing.expectEqual(@as(usize, 2), client.semaphore.?.permits);
}

test "Client: send redirect loop exceeds max redirects cleanly" {
    const allocator = std.testing.allocator;
    const io = std.testing.io;

    // Initial request + 2 redirects = 3 cycles
    const s = try startRedirectLoopServer(io, 3);
    defer s.thread.join();

    var client = try Self.init(allocator, io, .{ .load_ca_bundle = false });
    defer client.deinit();

    const url = try allocator.printSentinel("http://127.0.0.1:{d}/loop", .{s.port}, 0);
    defer allocator.free(url);

    const LimitHook = struct {
        fn hook(easy: *Easy) !void {
            try easy.setMaxRedirects(2);
        }
    };

    // Follows redirects but capped at 2, so loop will abort and return error
    const res = client.get(url)
        .configure(LimitHook.hook)
        .timeout(3000)
        .send(io);

    try std.testing.expectError(error.HttpTransferFailed, res);
}

test "Client: send double deinit is safe and idempotent" {
    const allocator = std.testing.allocator;
    const io = std.testing.io;

    const s = try startEmptyBodyServer(io);
    defer s.thread.join();

    var client = try Self.init(allocator, io, .{ .load_ca_bundle = false });
    defer client.deinit();

    const url = try allocator.printSentinel("http://127.0.0.1:{d}/", .{s.port}, 0);
    defer allocator.free(url);

    var res = try client.get(url).timeout(3000).send(io);

    // Call deinit twice explicitly (e.g. simulating defer res.deinit() + manual res.deinit())
    res.deinit();
    res.deinit();
}
