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
//! - `deinit`: The caller must ensure that all `Response` objects have been deinitialized
//!   via `res.deinit()` and all concurrent `send()` calls have finished before calling `client.deinit()`.
//!   Accessing `Response` methods after `res.deinit()` or after `client.deinit()` triggers a panic.
//!
//! Features:
//! - Fluent `RequestBuilder` API with zero heap allocation and standard slice syntax
//! - Transparent connection, DNS, and TLS session reuse via `CURLSH`
//! - Clean Easy handle pooling with automatic Taint-and-Dispose isolation
//! - Non-blocking fiber suspension and resumption via `std.Io.Event`
//! - Event-driven driver loop with zero idle CPU busy-wait
const std = @import("std");
const builtin = @import("builtin");
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
const Reader = std.Io.Reader;
const Writer = std.Io.Writer;
const SpinLock = Share.SpinLock;
const RawSpinLock = Share.RawSpinLock;
const ResizableBuffer = util.ResizableBuffer;
const Self = @This();

fn setTestReceiveTimeout(stream: std.Io.net.Stream) void {
    if (comptime builtin.os.tag == .windows) return;

    const tv = std.posix.timeval{ .sec = 2, .usec = 0 };
    _ = std.posix.setsockopt(
        stream.socket.handle,
        std.posix.SOL.SOCKET,
        std.posix.SO.RCVTIMEO,
        std.mem.asBytes(&tv),
    ) catch {};
}

pub const Header = ResponseHeader;
pub const HeaderIterator = ResponseHeaderIterator;
pub const HttpError = errors.HttpError;

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

/// Multi-producer, single-consumer pending queue protected by Rust-style SpinLock.
/// Caller threads push newly-initiated streams here via `send()`.
/// The background driver thread drains the entire list in one atomic step before multi-polling.
pending_queue: SpinLock(?*StreamContext) = .init(null),

/// Doubly-linked intrusive list of streams currently registered in `curl_multi`.
/// Exclusively owned and mutated by the background driver thread (100% lock-free).
/// When `active_list == null`, the driver suspends unconditionally on `idle_event` with zero CPU usage.
active_list: ?*StreamContext = null,

pub const HeaderEntry = struct {
    name: []const u8,
    value: []const u8,
};

pub const QueryParam = struct {
    name: []const u8,
    value: []const u8,
};

/// An immutable header name-value view into response metadata.
///
/// **Lifetime**: Valid ONLY until `res.deinit()` is called on the owning `Response`.
/// Accessing the string slices after `res.deinit()` is undefined behavior.
pub const ResponseHeader = struct {
    name: []const u8,
    value: []const u8,

    pub fn get(self: ResponseHeader) []const u8 {
        return self.value;
    }
};

const HeaderOffset = struct {
    name_start: u32,
    name_len: u32,
    val_start: u32,
    val_len: u32,
};

comptime {
    assert(@sizeOf(HeaderOffset) == 16);
}

/// Iterator over captured response headers.
///
/// **Lifetime**: Valid ONLY until `res.deinit()` is called on the owning `Response`.
///
/// Note: The Client API snapshots only the headers from the final HTTP response.
/// Intermediate redirect hops and HTTP chunked trailers are intentionally excluded.
pub const ResponseHeaderIterator = struct {
    stream: *const StreamContext,
    name_filter: ?[]const u8 = null,
    index: usize = 0,

    pub fn next(self: *ResponseHeaderIterator) ?ResponseHeader {
        while (self.index < self.stream.headers.items.len) {
            const h = self.stream.getHeaderByIndex(self.index);
            self.index += 1;
            if (self.name_filter) |filter| {
                if (std.ascii.eqlIgnoreCase(h.name, filter)) {
                    return h;
                }
            } else {
                return h;
            }
        }
        return null;
    }
};

pub const IterateHeadersOptions = struct {
    name: ?[]const u8 = null,
};

pub const BodyReader = struct {
    stream: *StreamContext,
    interface: std.Io.Reader,

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
            const n = self.stream.readBytes(buf) catch return error.ReadFailed;
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
        return self.stream.err;
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
    reader_buf: [4096]u8 = undefined,

    pub fn reader(self: *Response) BodyReader {
        const stream = self.stream orelse @panic("Response.reader() called after deinit()");
        return BodyReader.init(stream, &self.reader_buf);
    }

    /// Returns true if the HTTP response status code is in the 2xx range (200..=299).
    pub fn isSuccess(self: Response) bool {
        return self.status_code >= 200 and self.status_code < 300;
    }

    /// Returns true if the HTTP response status code is in the 4xx range (400..=499).
    pub fn isClientError(self: Response) bool {
        return self.status_code >= 400 and self.status_code < 500;
    }

    /// Returns true if the HTTP response status code is in the 5xx range (500..=599).
    pub fn isServerError(self: Response) bool {
        return self.status_code >= 500 and self.status_code < 600;
    }

    /// Returns true if the HTTP response indicates an error (4xx or 5xx).
    pub fn isError(self: Response) bool {
        return self.status_code >= 400 and self.status_code < 600;
    }

    /// Retrieve a response header by name from the captured header snapshot.
    /// Returns null if the header does not exist.
    /// Thread-safe: accesses immutable snapshot data captured on driver thread before headers_ready.
    /// The returned `Header` view is valid only until `res.deinit()` is called.
    /// Chunked trailers and intermediate redirect headers are not included in the snapshot.
    pub fn getHeader(self: *const Response, name: []const u8) ?Header {
        const stream = self.stream orelse @panic("Response.getHeader() called after deinit()");
        for (0..stream.headers.items.len) |i| {
            const h = stream.getHeaderByIndex(i);
            if (std.ascii.eqlIgnoreCase(h.name, name)) {
                return h;
            }
        }
        return null;
    }

    /// Iterate over response headers using the captured header snapshot.
    /// Thread-safe: accesses immutable snapshot data captured on driver thread before headers_ready.
    /// The returned iterator and its items are valid only until `res.deinit()` is called.
    /// Chunked trailers and intermediate redirect headers are not included in the snapshot.
    pub fn iterateHeaders(self: *const Response, options: IterateHeadersOptions) HeaderIterator {
        const stream = self.stream orelse @panic("Response.iterateHeaders() called after deinit()");
        return HeaderIterator{
            .stream = stream,
            .name_filter = options.name,
            .index = 0,
        };
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
        const stream = self.stream orelse @panic("Response.deinit() called multiple times");
        self.stream = null;

        const client = self.client;
        stream.releaseSemaphore();

        stream.mutex.lock();
        const is_done = stream.eof;
        stream.mutex.unlock();

        if (!is_done) {
            stream.aborted.store(true, .release);
            // Driver thread is actively in curl_multi_poll or executing; curl_multi_wakeup
            // is sufficient to wake it. idle_event.set is omitted as driver is not idle.
            _ = c.curl_multi_wakeup(client.multi);
        }

        stream.releaseRef();
    }
};

pub const StreamContext = struct {
    // Internal buffer size constants
    pub const ring_buffer_bytes_max: usize = 64 * 1024;
    pub const ring_unpause_threshold_bytes: usize = 16 * 1024;

    comptime {
        assert(ring_unpause_threshold_bytes > 0);
        assert(ring_unpause_threshold_bytes < ring_buffer_bytes_max);
    }

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

    // Reference count initialized to 2:
    // - 1 reference held by the background driver thread (while the transfer is active in curl_multi)
    // - 1 reference held by the caller / Response handle (released on Response.deinit or send() failure)
    // The underlying Easy handle and StreamContext are only recycled or destroyed when both have finished.
    ref_count: std.atomic.Value(u32) = std.atomic.Value(u32).init(2),
    mutex: RawSpinLock = .{},
    header_event: std.Io.Event = .unset,
    read_event: std.Io.Event = .unset,
    headers_ready: bool = false,
    eof: bool = false,
    aborted: std.atomic.Value(bool) = std.atomic.Value(bool).init(false),
    semaphore_released: std.atomic.Value(bool) = std.atomic.Value(bool).init(false),
    err: ?anyerror = null,
    paused: bool = false,
    needs_unpause: bool = false,
    is_tainted: bool = false,
    follow_location: bool = true,
    upload_reader: ?*Reader = null,

    // Header snapshot captured safely on the driver thread before headers_ready.
    // Stored in a single contiguous buffer with byte offsets to eliminate per-header allocations.
    header_bytes: std.ArrayList(u8) = .empty,
    headers: std.ArrayList(HeaderOffset) = .empty,

    ring_buffer: [ring_buffer_bytes_max]u8 = undefined,
    ring_head: usize = 0,
    ring_count: usize = 0,

    /// Dynamically allocated request payload (e.g. from `RequestBuilder.json()`).
    /// libcurl requires the body pointer to remain valid throughout the entire transfer;
    /// ownership is handed over from `RequestBuilder` into `StreamContext` on `send()`,
    /// and freed when this stream is reset, recycled, or destroyed.
    owned_body: ?[]const u8 = null,
    /// Dynamically allocated URL (e.g. from `RequestBuilder.query()`).
    /// libcurl requires the URL string to remain valid throughout the entire transfer;
    /// ownership is handed over from `RequestBuilder` into `StreamContext` on `send()`,
    /// and freed when this stream is reset, recycled, or destroyed.
    owned_url: ?[:0]const u8 = null,

    fn reset(
        self: *StreamContext,
        client: *Self,
        io: std.Io,
        easy: *Easy,
        is_tainted: bool,
        follow_location: bool,
        upload_reader: ?*Reader,
    ) void {
        assert(self.active_prev == null);
        assert(self.active_next == null);

        self.client = client;
        self.allocator = client.allocator;
        self.io = io;
        self.easy = easy;
        self.result = c.CURLE_OK;
        self.response_code = 0;
        if (self.c_headers) |h| {
            c.curl_slist_free_all(h);
            self.c_headers = null;
        }
        if (self.owned_body) |b| {
            self.allocator.free(b);
            self.owned_body = null;
        }
        if (self.owned_url) |u| {
            self.allocator.free(u);
            self.owned_url = null;
        }
        self.next = null;
        self.active_prev = null;
        self.active_next = null;
        self.ref_count.store(2, .release);
        self.header_event.reset();
        self.read_event.reset();
        self.headers_ready = false;
        self.eof = false;
        self.aborted.store(false, .release);
        self.semaphore_released.store(false, .release);
        self.err = null;
        self.paused = false;
        self.needs_unpause = false;
        self.is_tainted = is_tainted;
        self.follow_location = follow_location;
        self.upload_reader = upload_reader;

        // Shrink header capacity if oversized from a previous unusually large response
        const header_bytes_max_retention: usize = 16 * 1024;
        if (self.header_bytes.capacity > header_bytes_max_retention) {
            self.header_bytes.deinit(self.allocator);
            self.header_bytes = .empty;
        } else {
            self.header_bytes.clearRetainingCapacity();
        }

        const headers_max_retention: usize = 128;
        if (self.headers.capacity > headers_max_retention) {
            self.headers.deinit(self.allocator);
            self.headers = .empty;
        } else {
            self.headers.clearRetainingCapacity();
        }

        self.ring_head = 0;
        self.ring_count = 0;
    }

    fn getHeaderByIndex(self: *const StreamContext, index: usize) ResponseHeader {
        const off = self.headers.items[index];
        const bytes = self.header_bytes.items;
        return .{
            .name = bytes[off.name_start .. off.name_start + off.name_len],
            .value = bytes[off.val_start .. off.val_start + off.val_len],
        };
    }

    fn clearHeaders(self: *StreamContext) void {
        self.header_bytes.clearRetainingCapacity();
        self.headers.clearRetainingCapacity();
    }

    fn headerFail(self: *StreamContext, err: anyerror) usize {
        self.mutex.lock();
        if (self.err == null) {
            self.err = err;
        }
        self.mutex.unlock();
        return 0;
    }

    fn onTransferDone(self: *StreamContext, result: c.CURLcode) void {
        self.mutex.lock();
        self.result = result;

        if (!self.headers_ready) {
            self.headers_ready = true;
            self.header_event.set(self.io);
        }

        self.eof = true;
        if (result != c.CURLE_OK and self.err == null) {
            self.err = errors.httpErrorFrom(result);
        }
        self.read_event.set(self.io);
        self.mutex.unlock();

        self.releaseRef();
    }

    fn releaseSemaphore(self: *StreamContext) void {
        if (self.client.semaphore) |*semaphore| {
            if (!self.semaphore_released.swap(true, .acq_rel)) {
                semaphore.post(self.io);
            }
        }
    }

    fn destroy(self: *StreamContext, allocator: Allocator) void {
        if (self.c_headers) |h| {
            c.curl_slist_free_all(h);
            self.c_headers = null;
        }
        if (self.owned_body) |b| {
            allocator.free(b);
            self.owned_body = null;
        }
        if (self.owned_url) |u| {
            allocator.free(u);
            self.owned_url = null;
        }
        self.header_bytes.deinit(allocator);
        self.headers.deinit(allocator);
        self.easy.deinit();
        allocator.destroy(self.easy);
        allocator.destroy(self);
    }

    fn releaseRef(self: *StreamContext) void {
        if (self.ref_count.fetchSub(1, .acq_rel) == 1) {
            self.releaseSemaphore();

            if (self.c_headers) |h| {
                c.curl_slist_free_all(h);
                self.c_headers = null;
            }

            self.client.releaseHandle(self, self.is_tainted);
        }
    }

    fn readBytes(self: *StreamContext, dest: []u8) !usize {
        if (dest.len == 0) return 0;

        while (true) {
            self.mutex.lock();

            if (self.ring_count > 0) {
                const bytes_to_copy = @min(dest.len, self.ring_count);

                // Copy from circular ring_buffer using at most two slice copies
                const bytes_first_copy = @min(bytes_to_copy, self.ring_buffer.len - self.ring_head);
                @memcpy(dest[0..bytes_first_copy], self.ring_buffer[self.ring_head .. self.ring_head + bytes_first_copy]);

                const bytes_second_copy = bytes_to_copy - bytes_first_copy;
                if (bytes_second_copy > 0) {
                    @memcpy(dest[bytes_first_copy..bytes_to_copy], self.ring_buffer[0..bytes_second_copy]);
                }

                self.ring_head = (self.ring_head + bytes_to_copy) % self.ring_buffer.len;
                self.ring_count -= bytes_to_copy;

                var should_wakeup_driver = false;
                if (self.paused) {
                    const free_space = self.ring_buffer.len - self.ring_count;
                    if (free_space >= ring_unpause_threshold_bytes) {
                        self.paused = false;
                        self.needs_unpause = true;
                        should_wakeup_driver = true;
                    }
                }

                if (should_wakeup_driver) {
                    assert(c.curl_multi_wakeup(self.client.multi) == c.CURLM_OK);
                }

                self.mutex.unlock();

                return bytes_to_copy;
            }

            if (self.eof) {
                const err = self.err;
                self.mutex.unlock();
                if (err) |e| return e;
                return 0; // EOF
            }

            self.read_event.reset();
            self.mutex.unlock();
            self.read_event.waitUncancelable(self.io);
        }
    }
};

const HandlePool = struct {
    items: SpinLock(std.ArrayList(*StreamContext)) = .init(.empty),

    fn deinit(self: *HandlePool, allocator: Allocator) void {
        var guard = self.items.acquire();
        defer guard.unlock();

        for (guard.value.items) |stream| {
            stream.destroy(allocator);
        }
        guard.value.deinit(allocator);
    }

    fn acquire(self: *HandlePool) ?*StreamContext {
        var guard = self.items.acquire();
        defer guard.unlock();

        if (guard.value.items.len > 0) {
            return guard.value.pop();
        }
        return null;
    }

    fn len(self: *HandlePool) usize {
        var guard = self.items.acquire();
        defer guard.unlock();
        return guard.value.items.len;
    }

    fn release(self: *HandlePool, allocator: Allocator, stream: *StreamContext) !void {
        var guard = self.items.acquire();
        defer guard.unlock();

        // Limit maximum pool capacity to prevent unbounded idle memory growth.
        const pool_max_capacity = 64;
        if (guard.value.items.len < pool_max_capacity) {
            try guard.value.append(allocator, stream);
        } else {
            stream.destroy(allocator);
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
    /// The concurrency permit is held for the entire transfer lifecycle and returned
    /// when the stream's reference count drops to zero (i.e. both caller Response and
    /// driver background transfer have completed or aborted).
    max_concurrency: ?usize = null,
    /// Maximum duration (in milliseconds) to drain active in-flight transfers during client.deinit().
    /// Defaults to 5000ms (5 seconds). Setting to 0 disables draining entirely, immediately
    /// aborting all active transfers. Any transfers still active after this window will be cancelled.
    shutdown_timeout_ms: usize = 5000,
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

pub fn request(self: *Self, method: Easy.Method, url: [:0]const u8) RequestBuilder {
    return RequestBuilder.init(self, method, url);
}

fn makeVerb(comptime method: Easy.Method) fn (*Self, [:0]const u8) RequestBuilder {
    return struct {
        fn call(self: *Self, url: [:0]const u8) RequestBuilder {
            return self.request(method, url);
        }
    }.call;
}

pub const get = makeVerb(.GET);
pub const post = makeVerb(.POST);
pub const put = makeVerb(.PUT);
pub const delete = makeVerb(.DELETE);
pub const head = makeVerb(.HEAD);
pub const patch = makeVerb(.PATCH);

// -------------------------------------------------------------------------
// Internal Engine Execution
// -------------------------------------------------------------------------

fn acquireStream(self: *Self) !*StreamContext {
    if (self.pool.acquire()) |stream| {
        return stream;
    }
    return self.createFreshStream();
}

fn createFreshStream(self: *Self) !*StreamContext {
    const easy = try self.allocator.create(Easy);
    errdefer self.allocator.destroy(easy);

    easy.* = try Easy.init(.{
        .ca_bundle = self.ca_bundle,
    });
    errdefer easy.deinit();

    // Attach global shared handle to enable connection and cache reuse.
    try easy.setShare(self.share.handle);

    const stream = try self.allocator.create(StreamContext);
    errdefer self.allocator.destroy(stream);

    stream.* = .{
        .client = self,
        .allocator = self.allocator,
        .io = self.io,
        .easy = easy,
    };
    return stream;
}

fn releaseHandle(self: *Self, stream: *StreamContext, is_tainted: bool) void {
    if (stream.c_headers) |h| {
        c.curl_slist_free_all(h);
        stream.c_headers = null;
    }
    if (stream.owned_body) |b| {
        self.allocator.free(b);
        stream.owned_body = null;
    }
    if (stream.owned_url) |u| {
        self.allocator.free(u);
        stream.owned_url = null;
    }

    if (is_tainted) {
        // Tainted handles are disposable to prevent configuration pollution.
        stream.destroy(self.allocator);
    } else {
        stream.easy.reset();
        // Re-attach share handle after curl_easy_reset.
        // If re-attaching fails, gracefully degrade by destroying the handle rather than causing UB.
        stream.easy.setShare(self.share.handle) catch {
            stream.destroy(self.allocator);
            return;
        };
        self.pool.release(self.allocator, stream) catch {
            stream.destroy(self.allocator);
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

fn abortStream(stream: *StreamContext) void {
    _ = c.curl_easy_setopt(stream.easy.handle, c.CURLOPT_SHARE, @as(?*anyopaque, null));
    stream.result = c.CURLE_ABORTED_BY_CALLBACK;
    stream.is_tainted = true;
    stream.mutex.lock();
    if (stream.err == null) {
        stream.err = error.ClientClosed;
    }
    stream.mutex.unlock();
    stream.onTransferDone(stream.result);
}

fn maintainActiveStreams(self: *Self) void {
    var curr = self.active_list;
    while (curr) |stream| {
        const next = stream.active_next;
        if (stream.aborted.load(.acquire)) {
            self.unlinkActive(stream);
            assert(c.curl_multi_remove_handle(self.multi, stream.easy.handle) == c.CURLM_OK);

            stream.mutex.lock();
            stream.eof = true;
            stream.read_event.set(stream.io);
            stream.mutex.unlock();

            stream.releaseRef();
        } else {
            // Check if consumer thread unpaused the stream after freeing buffer space.
            // curl_easy_pause can synchronously re-enter streamWriteCallback on this driver thread,
            // so we inspect and reset the flag under lock, and call curl_easy_pause outside the lock.
            stream.mutex.lock();
            const do_unpause = stream.needs_unpause;
            stream.needs_unpause = false;
            stream.mutex.unlock();

            if (do_unpause) {
                const rc = c.curl_easy_pause(stream.easy.handle, c.CURLPAUSE_CONT);
                assert(rc == c.CURLE_OK);
            }
        }
        curr = next;
    }
}

fn streamUploadCallback(
    ptr: [*c]c_char,
    size: usize,
    nmemb: usize,
    user_data: ?*anyopaque,
) callconv(.c) usize {
    const total_bytes: usize = size * nmemb;
    if (total_bytes == 0) return 0;
    const stream: *StreamContext = @ptrCast(@alignCast(user_data orelse return c.CURL_READFUNC_ABORT));

    const upload_reader = stream.upload_reader orelse return c.CURL_READFUNC_ABORT;
    const dest: [*]u8 = @ptrCast(ptr);

    const n = upload_reader.readSliceShort(dest[0..total_bytes]) catch |err| {
        stream.mutex.lock();
        if (stream.err == null) {
            stream.err = err;
        }
        stream.mutex.unlock();
        return c.CURL_READFUNC_ABORT;
    };

    return n;
}

fn streamHeaderCallback(
    ptr: [*c]c_char,
    size: usize,
    nmemb: usize,
    user_data: ?*anyopaque,
) callconv(.c) usize {
    const total_bytes: usize = size * nmemb;
    if (total_bytes == 0) return 0;
    const stream: *StreamContext = @ptrCast(@alignCast(user_data.?));

    const bytes: [*]const u8 = @ptrCast(ptr);
    const line = bytes[0..total_bytes];

    // If headers_ready is already set, the response header snapshot has been frozen and
    // published to the caller thread. Any further header callback invocations represent
    // chunked trailers or post-header meta, which must NOT mutate the immutable snapshot.
    {
        stream.mutex.lock();
        const ready = stream.headers_ready;
        stream.mutex.unlock();
        if (ready) {
            return total_bytes;
        }
    }

    if (std.mem.startsWith(u8, line, "HTTP/")) {
        // Start of a response status line (either initial, or following a redirect).
        // Clear headers collected for any previous intermediate response hop.
        stream.clearHeaders();
        return total_bytes;
    }

    if ((line.len == 2 and line[0] == '\r' and line[1] == '\n') or
        (line.len == 1 and line[0] == '\n'))
    {
        var code: c_long = 0;
        _ = c.curl_easy_getinfo(stream.easy.handle, c.CURLINFO_RESPONSE_CODE, &code);

        // Informational responses (1xx) are intermediate; wait for final status line & headers.
        const is_informational = (code >= 100 and code < 200);

        // For 3xx responses: if follow_location is enabled AND the response has a Location header,
        // libcurl will follow this redirect (unless code is 304 Not Modified).
        // In that case, this is an intermediate redirect hop, so we do NOT publish headers_ready yet.
        var has_location = false;
        if (code >= 300 and code < 400 and code != 304 and stream.follow_location) {
            for (0..stream.headers.items.len) |i| {
                const h = stream.getHeaderByIndex(i);
                if (std.ascii.eqlIgnoreCase(h.name, "Location")) {
                    has_location = true;
                    break;
                }
            }
        }
        const is_intermediate_redirect = has_location;

        if (is_informational or is_intermediate_redirect) {
            // Keep collecting; intermediate headers will be cleared on the next "HTTP/" status line
        } else {
            stream.mutex.lock();
            stream.response_code = code;
            stream.headers_ready = true;
            stream.header_event.set(stream.io);
            stream.mutex.unlock();
        }
    } else {
        // Parse "Header-Name: Value\r\n" into contiguous buffer outside the spinlock
        // to eliminate 2 individual heap allocations per header.
        if (std.mem.indexOfScalar(u8, line, ':')) |colon_index| {
            const raw_name = std.mem.trim(u8, line[0..colon_index], " \t\r\n");
            const raw_value = std.mem.trim(u8, line[colon_index + 1 ..], " \t\r\n");

            const prev_len = stream.header_bytes.items.len;
            stream.header_bytes.appendSlice(stream.allocator, raw_name) catch |e| return stream.headerFail(e);
            const name_end = stream.header_bytes.items.len;
            stream.header_bytes.appendSlice(stream.allocator, raw_value) catch |e| {
                stream.header_bytes.shrinkRetainingCapacity(prev_len);
                return stream.headerFail(e);
            };
            const val_end = stream.header_bytes.items.len;

            stream.headers.append(stream.allocator, .{
                .name_start = @intCast(prev_len),
                .name_len = @intCast(name_end - prev_len),
                .val_start = @intCast(name_end),
                .val_len = @intCast(val_end - name_end),
            }) catch |e| {
                stream.header_bytes.shrinkRetainingCapacity(prev_len);
                return stream.headerFail(e);
            };
        }
    }

    return total_bytes;
}

fn streamWriteCallback(
    ptr: [*c]c_char,
    size: usize,
    nmemb: usize,
    user_data: ?*anyopaque,
) callconv(.c) usize {
    const total_bytes: usize = size * nmemb;
    if (total_bytes == 0) return 0;
    const stream: *StreamContext = @ptrCast(@alignCast(user_data.?));

    stream.mutex.lock();

    // In HTTP semantics, headers (and their terminating CRLF) always precede body chunks.
    // Therefore, stream.headers_ready is guaranteed to be true before write callback runs.
    assert(stream.headers_ready);

    if (stream.aborted.load(.acquire)) {
        if (stream.err == null) {
            stream.err = error.ClientClosed;
        }
        stream.mutex.unlock();
        return 0; // Abort transfer immediately with consistent ClientClosed classification
    }

    const available = stream.ring_buffer.len - stream.ring_count;
    if (available < total_bytes) {
        stream.paused = true;
        stream.mutex.unlock();
        return @as(usize, @intCast(c.CURL_WRITEFUNC_PAUSE));
    }

    const bytes: [*]const u8 = @ptrCast(ptr);
    const ring_tail = (stream.ring_head + stream.ring_count) % stream.ring_buffer.len;
    const bytes_first_copy = @min(total_bytes, stream.ring_buffer.len - ring_tail);
    @memcpy(stream.ring_buffer[ring_tail .. ring_tail + bytes_first_copy], bytes[0..bytes_first_copy]);

    const bytes_second_copy = total_bytes - bytes_first_copy;
    if (bytes_second_copy > 0) {
        @memcpy(stream.ring_buffer[0..bytes_second_copy], bytes[bytes_first_copy..total_bytes]);
    }
    stream.ring_count += total_bytes;

    stream.read_event.set(stream.io);
    stream.mutex.unlock();

    return total_bytes;
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

    // Drain remaining transfers on shutdown with bounded iterations.
    // Iterations are derived dynamically from options.shutdown_timeout_ms.
    self.drainPendingQueue();
    self.maintainActiveStreams();
    if (self.active_list != null) {
        var still_running: c_int = 1;
        var drain_elapsed: usize = 0;
        const poll_step_ms: usize = 50;
        while (still_running > 0 and drain_elapsed < self.options.shutdown_timeout_ms) : (drain_elapsed += poll_step_ms) {
            self.maintainActiveStreams();
            const drain_perform_rc = c.curl_multi_perform(self.multi, &still_running);
            assert(drain_perform_rc == c.CURLM_OK);
            self.processDoneTransfers();
            var num_fds: c_int = 0;
            const drain_poll_rc = c.curl_multi_poll(self.multi, null, 0, @intCast(poll_step_ms), &num_fds);
            assert(drain_poll_rc == c.CURLM_OK);
        }
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
    var unhandled: ?*StreamContext = null;
    {
        var guard = self.pending_queue.acquire();
        unhandled = guard.value.*;
        guard.value.* = null;
        guard.unlock();
    }
    while (unhandled) |stream| {
        const next = stream.next;
        abortStream(stream);
        unhandled = next;
    }
}

fn drainPendingQueue(self: *Self) void {
    var raw_list: ?*StreamContext = null;
    {
        var guard = self.pending_queue.acquire();
        raw_list = guard.value.*;
        guard.value.* = null;
        guard.unlock();
    }

    // Reverse the LIFO push order to restore natural FIFO request submission
    var fifo_head: ?*StreamContext = null;
    var curr = raw_list;
    while (curr) |stream| {
        const next = stream.next;
        stream.next = fifo_head;
        fifo_head = stream;
        curr = next;
    }

    var item = fifo_head;
    while (item) |stream| {
        const next = stream.next;
        const rc = c.curl_multi_add_handle(self.multi, stream.easy.handle);
        if (rc != c.CURLM_OK) {
            stream.result = c.CURLE_FAILED_INIT;
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
    body_reader: ?*Reader = null,
    body_reader_size: ?usize = null,
    request_timeout: ?std.Io.Timeout = null,
    max_redirects: ?u32 = null,
    http_version: ?Easy.HttpVersion = null,
    follow_location: bool = true,
    unix_socket_path: ?[:0]const u8 = null,
    is_tainted: bool = false,
    config_hook: ?*const fn (*Easy) anyerror!void = null,
    /// Holds ownership of a heap-allocated JSON payload produced by `.json()`.
    /// Transferred to `StreamContext.owned_body` inside `send()`.
    owned_body: ?[]const u8 = null,
    /// Holds ownership of a heap-allocated query-encoded URL produced by `.query()`.
    /// Transferred to `StreamContext.owned_url` inside `send()`.
    owned_url: ?[:0]const u8 = null,
    has_json_body: bool = false,

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
        s.body_reader = null;
        s.body_reader_size = null;
        return s;
    }

    /// Sets streaming request body data from an active `std.Io.Reader`.
    ///
    /// For POST requests, CURLOPT_POST is configured and CURLOPT_POSTFIELDSIZE_LARGE is used
    /// when content_length is provided (otherwise chunked transfer encoding is enabled).
    /// For PUT/other requests, CURLOPT_UPLOAD and CURLOPT_INFILESIZE_LARGE are configured.
    ///
    /// Thread Model & Concurrency Hazard:
    /// The reader is pulled synchronously from libcurl's read callback inside the dedicated background
    /// driver thread. Therefore, `reader` MUST be completely independent and must NOT depend on this
    /// `Client` instance to make progress (e.g. streaming another Response from this same Client will deadlock).
    /// Furthermore, `std.Io.Reader` is not thread-safe and must not be read concurrently elsewhere.
    ///
    /// Lifetime contract: `send()` returns as soon as response headers arrive, while upload streaming
    /// may continue concurrently in the background driver thread. The caller must ensure that `reader`
    /// remains valid until the returned `Response` is deinitialized via `res.deinit()`, or until
    /// the full transfer completes.
    ///
    /// Upload Rewind & Redirect Limitation:
    /// `bodyReader` provides a forward-only stream without rewind capabilities (`CURLOPT_SEEKFUNCTION`).
    /// If the server responds with a redirect that requires resending the body (such as HTTP 307/308) or
    /// an authentication challenge (HTTP 401/407), libcurl cannot rewind the stream and the request
    /// will fail with `error.UploadNotRewindable`. For streaming uploads, consider setting
    /// `.followLocation(false)` or configuring `CURLOPT_SEEKFUNCTION` via `.configure()`.
    pub fn bodyReader(self: RequestBuilder, reader: *Reader, content_length: ?usize) RequestBuilder {
        var s = self;
        s.body_reader = reader;
        s.body_reader_size = content_length;
        s.body_data = null;
        return s;
    }

    /// Sets the maximum number of redirects libcurl will follow.
    /// Note: Passing 0 strictly refuses redirects (resulting in error.TooManyRedirects if a redirect is encountered).
    /// To accept the 3xx response without following, use `followLocation(false)` instead.
    pub fn maxRedirects(self: RequestBuilder, n: u32) RequestBuilder {
        var s = self;
        s.max_redirects = n;
        return s;
    }

    /// Sets the request timeout using `std.Io.Timeout`.
    /// When evaluated during `send(io)`, the timeout is resolved relative to `io`'s current clock into milliseconds.
    pub fn timeout(self: RequestBuilder, t: std.Io.Timeout) RequestBuilder {
        var s = self;
        s.request_timeout = t;
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

    /// Serializes `payload` to JSON, sets it as the request body, and ensures `Content-Type: application/json` is sent.
    /// Memory allocated for the JSON string is owned by the request and automatically released when the transfer completes.
    pub fn json(self: RequestBuilder, payload: anytype) !RequestBuilder {
        var s = self;
        if (s.owned_body) |b| {
            s.client.allocator.free(b);
            s.owned_body = null;
        }
        const json_str = try std.fmt.allocPrint(s.client.allocator, "{f}", .{std.json.fmt(payload, .{})});
        s.body_data = json_str;
        s.owned_body = json_str;
        s.body_reader = null;
        s.body_reader_size = null;
        s.has_json_body = true;
        return s;
    }

    /// Appends query parameters to the URL.
    /// `params` can be either a slice of `QueryParam` / key-value structs, or an anonymous struct whose fields are key-value pairs.
    /// Keys and values are automatically URL-encoded using libcurl.
    /// The newly constructed URL is owned by the request and automatically released when the transfer completes.
    pub fn query(self: RequestBuilder, params: anytype) !RequestBuilder {
        var s = self;
        const T = @TypeOf(params);
        const type_info = @typeInfo(T);

        var list: std.ArrayList(u8) = .empty;
        defer list.deinit(s.client.allocator);

        try list.appendSlice(s.client.allocator, s.url);

        var has_query_mark = std.mem.indexOfScalar(u8, s.url, '?') != null;

        switch (type_info) {
            .pointer => |ptr_info| {
                switch (ptr_info.size) {
                    .slice => {
                        for (params) |param| {
                            const name_str = param.name;
                            const val_str = param.value;
                            try appendEncodedParam(s.client.allocator, &list, name_str, val_str, &has_query_mark);
                        }
                    },
                    else => @compileError("query() expects a slice of query params or a struct"),
                }
            },
            .@"struct" => |struct_info| {
                inline for (struct_info.field_names) |field_name| {
                    const raw_val = @field(params, field_name);
                    const val_str = try formatQueryValAlloc(s.client.allocator, raw_val);
                    defer s.client.allocator.free(val_str);
                    try appendEncodedParam(s.client.allocator, &list, field_name, val_str, &has_query_mark);
                }
            },
            else => @compileError("query() expects a slice of query params or a struct"),
        }

        const new_url = try s.client.allocator.dupeSentinel(u8, list.items, 0);
        if (s.owned_url) |u| {
            s.client.allocator.free(u);
        }
        s.owned_url = new_url;
        s.url = new_url;
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

    fn setupAndEnqueue(
        self: RequestBuilder,
        io: std.Io,
    ) !*StreamContext {
        assert(self.url.len > 0);
        const client = self.client;

        if (client.semaphore) |*sem| {
            try sem.wait(io);
        }
        errdefer if (client.semaphore) |*sem| {
            sem.post(io);
        };

        const stream = if (self.is_tainted)
            try client.createFreshStream()
        else
            try client.acquireStream();

        errdefer client.releaseHandle(stream, self.is_tainted);

        stream.reset(
            client,
            io,
            stream.easy,
            self.is_tainted,
            self.follow_location,
            self.body_reader,
        );
        const easy = stream.easy;

        try easy.setUrl(self.url);
        try easy.setMethod(self.method);
        if (self.method == .HEAD) {
            try checkCode(
                c.curl_easy_setopt(easy.handle, c.CURLOPT_NOBODY, @as(c_long, 1)),
                &easy.diagnostics,
            );
        }
        try easy.setFollowLocation(self.follow_location);

        if (self.max_redirects) |redirs| {
            try easy.setMaxRedirects(redirs);
        }

        if (self.request_timeout) |to| {
            if (to.toDurationFromNow(io)) |d| {
                const ms = d.raw.toMilliseconds();
                if (ms > 0) {
                    easy.timeout_ms = @intCast(ms);
                } else {
                    // Timeout has already expired prior to dispatch
                    easy.timeout_ms = 1;
                }
            } else {
                // .none explicitly disables timeout
                easy.timeout_ms = 0;
            }
        }
        if (self.http_version) |ver| {
            try easy.setHttpVersion(ver);
        }
        if (self.unix_socket_path) |path| {
            try easy.setUnixSocketPath(path);
        }
        if (self.body_data) |b| {
            try easy.setPostFields(b);
        } else if (self.body_reader) |_| {
            try checkCode(c.curl_easy_setopt(easy.handle, c.CURLOPT_READFUNCTION, streamUploadCallback), &easy.diagnostics);
            try checkCode(c.curl_easy_setopt(easy.handle, c.CURLOPT_READDATA, stream), &easy.diagnostics);
            if (self.method == .POST) {
                try checkCode(c.curl_easy_setopt(easy.handle, c.CURLOPT_POST, @as(c_long, 1)), &easy.diagnostics);
                if (self.body_reader_size) |sz| {
                    try checkCode(c.curl_easy_setopt(easy.handle, c.CURLOPT_POSTFIELDSIZE_LARGE, @as(c_longlong, @intCast(sz))), &easy.diagnostics);
                } else {
                    // When streaming POST without known size, libcurl requires chunked transfer encoding
                    try checkCode(c.curl_easy_setopt(easy.handle, c.CURLOPT_POSTFIELDSIZE_LARGE, @as(c_longlong, -1)), &easy.diagnostics);
                }
            } else {
                try checkCode(c.curl_easy_setopt(easy.handle, c.CURLOPT_UPLOAD, @as(c_int, 1)), &easy.diagnostics);
                if (self.body_reader_size) |sz| {
                    try checkCode(c.curl_easy_setopt(easy.handle, c.CURLOPT_INFILESIZE_LARGE, @as(c_longlong, @intCast(sz))), &easy.diagnostics);
                }
            }
        }

        // Custom headers
        const ch = try buildHeaderSlist(client.allocator, self.custom_headers, self.has_json_body);
        stream.c_headers = ch;
        if (ch) |headers_list| {
            try easy.setHeadersC(headers_list);
        }

        // Transfer ownership of allocated body and URL buffers to stream so they are freed upon reset or destroy.
        stream.owned_body = self.owned_body;
        stream.owned_url = self.owned_url;

        try easy.setCommonOpts();

        if (self.config_hook) |hook| {
            try hook(easy);
        }

        try checkCode(c.curl_easy_setopt(easy.handle, c.CURLOPT_WRITEFUNCTION, streamWriteCallback), &easy.diagnostics);
        try checkCode(c.curl_easy_setopt(easy.handle, c.CURLOPT_WRITEDATA, stream), &easy.diagnostics);
        try checkCode(c.curl_easy_setopt(easy.handle, c.CURLOPT_HEADERFUNCTION, streamHeaderCallback), &easy.diagnostics);
        try checkCode(c.curl_easy_setopt(easy.handle, c.CURLOPT_HEADERDATA, stream), &easy.diagnostics);
        // Suppress proxy CONNECT response headers from entering the header callback if supported (libcurl >= 7.54.0)
        if (comptime c.CURL_AT_LEAST_VERSION(7, 54, 0)) {
            if (@hasDecl(c, "CURLOPT_SUPPRESS_CONNECT_HEADERS")) {
                try checkCode(c.curl_easy_setopt(easy.handle, c.CURLOPT_SUPPRESS_CONNECT_HEADERS, @as(c_long, 1)), &easy.diagnostics);
            }
        }

        try easy.setPrivate(stream);

        // Enqueue to pending queue and wake driver.
        // Once enqueued, ownership is managed by the driver thread and Response.
        {
            var guard = client.pending_queue.acquire();
            defer guard.unlock();
            stream.next = guard.value.*;
            guard.value.* = stream;
        }

        client.idle_event.set(client.io);
        const wakeup_rc = c.curl_multi_wakeup(client.multi);
        assert(wakeup_rc == c.CURLM_OK);

        return stream;
    }

    /// Send the HTTP request asynchronously and return a `Response` as soon as headers are received.
    /// The response body can be read incrementally via `res.reader()` or fully buffered via `res.bodyAlloc()`.
    ///
    /// Lifetime contract: The returned `Response` must be closed (via `res.deinit()`)
    /// before `client.deinit()` is called, as the active stream borrows internal resources (easy handle,
    /// connection share context, and semaphore permits) from the `Client`.
    pub fn send(self: RequestBuilder, io: std.Io) !Response {
        const stream = try self.setupAndEnqueue(io);

        // Wait until headers are received or transfer fails
        stream.header_event.waitUncancelable(io);

        stream.mutex.lock();
        const transfer_failed = stream.result != c.CURLE_OK;
        const result = stream.result;
        const stream_err = stream.err;
        const response_code = stream.response_code;
        stream.mutex.unlock();

        if (transfer_failed) {
            stream.releaseSemaphore();
            stream.releaseRef();
            if (stream_err) |e| return e;
            return errors.httpErrorFrom(result);
        }

        return Response{
            .client = self.client,
            .status_code = @intCast(response_code),
            .stream = stream,
        };
    }
};

fn appendEncodedParam(
    allocator: Allocator,
    list: *std.ArrayList(u8),
    key: []const u8,
    val: []const u8,
    has_query_mark: *bool,
) !void {
    if (!has_query_mark.*) {
        try list.append(allocator, '?');
        has_query_mark.* = true;
    } else {
        try list.append(allocator, '&');
    }

    const enc_key = c.curl_easy_escape(null, key.ptr, @intCast(key.len)) orelse return error.OutOfMemory;
    defer c.curl_free(enc_key);
    try list.appendSlice(allocator, std.mem.sliceTo(enc_key, 0));

    try list.append(allocator, '=');

    const enc_val = c.curl_easy_escape(null, val.ptr, @intCast(val.len)) orelse return error.OutOfMemory;
    defer c.curl_free(enc_val);
    try list.appendSlice(allocator, std.mem.sliceTo(enc_val, 0));
}

fn formatQueryValAlloc(allocator: Allocator, val: anytype) ![]u8 {
    const ValType = @TypeOf(val);
    const val_type_info = @typeInfo(ValType);
    if (val_type_info == .pointer) {
        if (val_type_info.pointer.size == .slice and val_type_info.pointer.child == u8) {
            return allocator.dupe(u8, val);
        }
        if (val_type_info.pointer.size == .one and @typeInfo(val_type_info.pointer.child) == .array and @typeInfo(val_type_info.pointer.child).array.child == u8) {
            return allocator.dupe(u8, val);
        }
    }
    return std.fmt.allocPrint(allocator, "{any}", .{val});
}

fn buildHeaderSlist(allocator: Allocator, entries: []const HeaderEntry, has_json_body: bool) !?*c.struct_curl_slist {
    var has_content_type = false;
    for (entries) |h| {
        if (std.ascii.eqlIgnoreCase(h.name, "Content-Type")) {
            has_content_type = true;
            break;
        }
    }

    if (entries.len == 0 and (!has_json_body or has_content_type)) return null;

    var ch: ?*c.struct_curl_slist = null;
    errdefer if (ch) |h| c.curl_slist_free_all(h);

    if (has_json_body and !has_content_type) {
        ch = c.curl_slist_append(ch, "Content-Type: application/json") orelse return error.OutOfMemory;
    }

    for (entries) |h| {
        // Use stack buffer for common headers to eliminate heap allocation.
        // Falls back to allocator only if the header line exceeds the stack capacity.
        var stack_buf: [512]u8 = undefined;
        if (std.fmt.bufPrintSentinel(&stack_buf, "{s}: {s}", .{ h.name, h.value }, 0)) |line| {
            ch = c.curl_slist_append(ch, line.ptr) orelse return error.OutOfMemory;
        } else |_| {
            const line = try allocator.printSentinel("{s}: {s}", .{ h.name, h.value }, 0);
            defer allocator.free(line);
            ch = c.curl_slist_append(ch, line.ptr) orelse return error.OutOfMemory;
        }
    }
    return ch;
}

// -------------------------------------------------------------------------
// Unit Tests
// -------------------------------------------------------------------------

fn testTimeout(ms: i64) std.Io.Timeout {
    return .{
        .duration = .{
            .raw = std.Io.Duration.fromMilliseconds(ms),
            .clock = .awake,
        },
    };
}

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
    assert(client.pool.len() == 0);

    // Acquire a clean stream
    const s1 = try client.acquireStream();
    assert(client.pool.len() == 0);

    // Release clean stream -> returns to pool
    client.releaseHandle(s1, false);
    assert(client.pool.len() == 1);

    // Acquire another stream -> should reuse from pool
    const s2 = try client.acquireStream();
    assert(s2 == s1);
    assert(client.pool.len() == 0);

    // Release tainted stream -> destroyed immediately, pool remains empty
    client.releaseHandle(s2, true);
    assert(client.pool.len() == 0);
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
        .timeout(testTimeout(3000))
        .version(.http2)
        .followLocation(false);

    assert(req1.is_tainted == false);
    assert(req1.request_timeout.?.toDurationFromNow(io).?.raw.toMilliseconds() > 0);
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

            // Configure socket receive timeout to prevent test deadlock if client fails to send
            setTestReceiveTimeout(stream);

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
    var res = try client.get(url).timeout(testTimeout(3000)).send(io);
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
        .timeout(testTimeout(3000))
        .send(io);

    assert(res.status_code == 200);
    const body = try res.bodyAlloc(allocator, 1024);
    defer allocator.free(body);
    assert(std.mem.eql(u8, body, "OK"));

    res.deinit();
    // Clean handle has been returned to pool after res.deinit()
    assert(client.pool.len() == 1);
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
        .timeout(testTimeout(3000))
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

    var res = try client.head(url).timeout(testTimeout(3000)).send(io);
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

    var res = try client.get(url).timeout(testTimeout(3000)).send(io);
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

    var res = try client.get(url).timeout(testTimeout(3000)).send(io);
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

    var res = try client.get(url).timeout(testTimeout(3000)).send(io);
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

    var res = try client.get(url).timeout(testTimeout(3000)).send(io);
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

            // Configure socket receive timeout to prevent test deadlock if client fails to send
            setTestReceiveTimeout(stream);

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

            // Configure socket receive timeout to prevent test deadlock if client fails to send
            setTestReceiveTimeout(stream);

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

    var res = try client.get(url).timeout(testTimeout(5000)).send(io);
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

    var res1 = try client.get(url1).timeout(testTimeout(5000)).send(io);
    defer res1.deinit();
    var res2 = try client.get(url2).timeout(testTimeout(5000)).send(io);
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

    var res = try client.get(url).timeout(testTimeout(5000)).send(io);
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

    var res = try client.get(url).timeout(testTimeout(400)).send(io);
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

test "Client: send connection failure fails cleanly without UAF or double-free" {
    const allocator = std.testing.allocator;
    const io = std.testing.io;

    var client = try Self.init(allocator, io, .{ .load_ca_bundle = false });
    defer client.deinit();

    // Windows runners do not reject this port immediately and report a timeout instead.
    // Unix loopback stacks reject it immediately with a connection failure.
    const res = client.get("http://127.0.0.1:1/")
        .headers(&.{.{ .name = "X-Test", .value = "UAF-Check" }})
        .timeout(testTimeout(1000))
        .send(io);

    if (comptime builtin.os.tag == .windows) {
        try std.testing.expectError(error.Timeout, res);
    } else {
        try std.testing.expectError(error.ConnectionFailed, res);
    }
}

test "Client: send DNS failure fails cleanly without UAF or double-free" {
    const allocator = std.testing.allocator;
    const io = std.testing.io;

    var client = try Self.init(allocator, io, .{ .load_ca_bundle = false });
    defer client.deinit();

    const res = client.get("http://invalid.domain.that.does.not.exist.test/")
        .headers(&.{.{ .name = "X-Test", .value = "DNS-Check" }})
        .timeout(testTimeout(1000))
        .send(io);

    // Depending on environment/proxy setup, DNS failure can yield NameResolutionFailed or HttpConnectionClosed
    if (res) |_| {
        return error.ExpectedFailure;
    } else |err| {
        try std.testing.expect(err == error.NameResolutionFailed or err == error.HttpConnectionClosed);
    }
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

            // Configure socket receive timeout to prevent test deadlock if client fails to send
            setTestReceiveTimeout(stream);

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

    var res = try client.get(url).timeout(testTimeout(3000)).send(io);
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

    var res = try client.get(url).timeout(testTimeout(5000)).send(io);
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
    var res1 = try client.get(url).timeout(testTimeout(3000)).send(io);
    try std.testing.expectEqual(@as(usize, 1), client.semaphore.?.permits);

    // Stream 2 acquires 1 permit -> 0 left (exhausted)
    var res2 = try client.get(url).timeout(testTimeout(3000)).send(io);
    try std.testing.expectEqual(@as(usize, 0), client.semaphore.?.permits);

    // Deinit stream 1: releases 1 permit back to semaphore immediately without waiting for driver
    res1.deinit();
    try std.testing.expectEqual(@as(usize, 1), client.semaphore.?.permits);

    // Deinit stream 2: releases second permit back
    res2.deinit();
    try std.testing.expectEqual(@as(usize, 2), client.semaphore.?.permits);
}

test "Client: max_concurrency=1 early deinit mid-stream releases permit immediately" {
    const allocator = std.testing.allocator;
    const io = std.testing.io;

    // Start streaming server delivering 1MiB
    const s = try startStreamingBytesServer(io, 1024 * 1024, 'S');
    defer s.thread.join();

    // Client with strict concurrency cap of 1
    var client = try Self.init(allocator, io, .{
        .max_concurrency = 1,
        .load_ca_bundle = false,
    });
    defer client.deinit();

    const url = try allocator.printSentinel("http://127.0.0.1:{d}/", .{s.port}, 0);
    defer allocator.free(url);

    // Initial permits: 1
    try std.testing.expectEqual(@as(usize, 1), client.semaphore.?.permits);

    // Request 1 acquires the only permit
    var res1 = try client.get(url).timeout(testTimeout(5000)).send(io);
    try std.testing.expectEqual(@as(usize, 0), client.semaphore.?.permits);

    // Read only a small chunk so the transfer is still active in the background
    var reader = res1.reader();
    var buf: [128]u8 = undefined;
    const n = try reader.read(&buf);
    try std.testing.expect(n > 0);

    // Deinit mid-stream: permit must be restored immediately to 1
    res1.deinit();
    try std.testing.expectEqual(@as(usize, 1), client.semaphore.?.permits);

    // Immediately acquire again without deadlocking or waiting for driver thread teardown
    try client.semaphore.?.wait(io);
    try std.testing.expectEqual(@as(usize, 0), client.semaphore.?.permits);
    client.semaphore.?.post(io);
    try std.testing.expectEqual(@as(usize, 1), client.semaphore.?.permits);
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
        .timeout(testTimeout(3000))
        .send(io);

    try std.testing.expectError(error.TooManyRedirects, res);
}

test "Client: getHeader and iterateHeaders on Response (offline local)" {
    const allocator = std.testing.allocator;
    const io = std.testing.io;

    const raw_response =
        "HTTP/1.1 200 OK\r\n" ++
        "Content-Length: 5\r\n" ++
        "X-Custom-Header: HelloCurl\r\n" ++
        "X-Multi-Header: Val1\r\n" ++
        "X-Multi-Header: Val2\r\n" ++
        "\r\n" ++
        "hello";

    const s = try startMockServer(io, raw_response);
    defer s.thread.join();

    var client = try Self.init(allocator, io, .{ .load_ca_bundle = false });
    defer client.deinit();

    const url = try allocator.printSentinel("http://127.0.0.1:{d}/", .{s.port}, 0);
    defer allocator.free(url);

    var res = try client.get(url).timeout(testTimeout(3000)).send(io);
    defer res.deinit();

    try std.testing.expectEqual(@as(u16, 200), res.status_code);

    // Test getHeader
    if (res.getHeader("x-custom-header")) |h| {
        try std.testing.expectEqualStrings("HelloCurl", h.get());
    } else {
        return error.HeaderNotFound;
    }

    const missing_h = res.getHeader("x-non-existent");
    try std.testing.expect(missing_h == null);

    // Test iterateHeaders
    var it = res.iterateHeaders(.{});
    var count: usize = 0;
    while (it.next()) |hdr| {
        if (std.ascii.eqlIgnoreCase(hdr.name, "X-Custom-Header")) {
            count += 1;
        }
    }
    try std.testing.expectEqual(@as(usize, 1), count);

    // Test multi-header iteration
    var multi_it = res.iterateHeaders(.{ .name = "x-multi-header" });
    const m1 = multi_it.next() orelse return error.MissingMultiHeader;
    try std.testing.expectEqualStrings("Val1", m1.get());
    const m2 = multi_it.next() orelse return error.MissingMultiHeader;
    try std.testing.expectEqualStrings("Val2", m2.get());
    try std.testing.expect(multi_it.next() == null);

    // getHeader returns the first header value
    const first_multi = res.getHeader("x-multi-header") orelse return error.MissingMultiHeader;
    try std.testing.expectEqualStrings("Val1", first_multi.get());

    const body = try res.bodyAlloc(allocator, 100);
    defer allocator.free(body);
    try std.testing.expectEqualStrings("hello", body);
}

test "Client: many headers forcing allocation growth and chunked trailers (offline local)" {
    const allocator = std.testing.allocator;
    const io = std.testing.io;

    // Construct a response with 60 headers (to force repeated allocations) followed by chunked body and trailers
    var raw_builder: std.ArrayList(u8) = .empty;
    defer raw_builder.deinit(allocator);

    try raw_builder.appendSlice(allocator, "HTTP/1.1 200 OK\r\nTransfer-Encoding: chunked\r\nTrailer: X-Trailer-Checksum\r\n");
    var i: usize = 0;
    while (i < 60) : (i += 1) {
        var line_buf: [64]u8 = undefined;
        const line = try std.fmt.bufPrint(&line_buf, "X-Header-{d}: Value-For-{d}\r\n", .{ i, i });
        try raw_builder.appendSlice(allocator, line);
    }
    // End of initial headers
    try raw_builder.appendSlice(allocator, "\r\n");
    // Chunked data: 5 bytes "hello", then 0 chunk, then trailer
    try raw_builder.appendSlice(allocator, "5\r\nhello\r\n0\r\nX-Trailer-Checksum: abc123def\r\n\r\n");

    const s = try startMockServer(io, raw_builder.items);
    defer s.thread.join();

    var client = try Self.init(allocator, io, .{ .load_ca_bundle = false });
    defer client.deinit();

    const url = try allocator.printSentinel("http://127.0.0.1:{d}/trailers", .{s.port}, 0);
    defer allocator.free(url);

    var res = try client.get(url).timeout(testTimeout(3000)).send(io);
    defer res.deinit();

    try std.testing.expectEqual(@as(u16, 200), res.status_code);

    // Verify all 60 headers exist and have not been corrupted by reallocation
    var j: usize = 0;
    while (j < 60) : (j += 1) {
        var name_buf: [32]u8 = undefined;
        var val_buf: [32]u8 = undefined;
        const name = try std.fmt.bufPrint(&name_buf, "X-Header-{d}", .{j});
        const expected_val = try std.fmt.bufPrint(&val_buf, "Value-For-{d}", .{j});

        const hdr = res.getHeader(name) orelse return error.HeaderMissing;
        try std.testing.expectEqualStrings(expected_val, hdr.get());
    }

    // Trailers must NOT pollute the initial response header snapshot
    try std.testing.expect(res.getHeader("X-Trailer-Checksum") == null);

    const body = try res.bodyAlloc(allocator, 100);
    defer allocator.free(body);
    try std.testing.expectEqualStrings("hello", body);
}

fn startEchoServer(io: std.Io) !struct { thread: std.Thread, port: u16 } {
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

            // Configure socket receive timeout to prevent test deadlock if client fails to send
            setTestReceiveTimeout(stream);

            var read_buf: [4096]u8 = undefined;
            var reader = std.Io.net.Stream.Reader.init(stream, ctx.io, &read_buf);
            var write_buf: [4096]u8 = undefined;
            var writer = std.Io.net.Stream.Writer.init(stream, ctx.io, &write_buf);

            var http_server = std.http.Server.init(&reader.interface, &writer.interface);
            var req = http_server.receiveHead() catch return;

            var body_buf: [4096]u8 = undefined;
            var server_req_reader_buf: [1024]u8 = undefined;
            var total_body_read: usize = 0;

            if (req.head.method == .POST or req.head.method == .PUT) {
                if (req.readerExpectContinue(&server_req_reader_buf)) |req_r| {
                    while (true) {
                        const n = req_r.readSliceShort(body_buf[total_body_read..]) catch break;
                        if (n == 0) break;
                        total_body_read += n;
                        if (total_body_read == body_buf.len) break;
                    }
                } else |_| {}
            }

            const is_post = (req.head.method == .POST);
            const is_put = (req.head.method == .PUT);
            var header_buf: [128]u8 = undefined;
            var header_writer = std.Io.Writer.fixed(&header_buf);
            header_writer.print("HTTP/1.1 200 OK\r\nContent-Length: {d}\r\nX-Received-Method: {s}\r\n\r\n", .{
                total_body_read,
                if (is_post) "POST" else if (is_put) "PUT" else "OTHER",
            }) catch return;

            writer.interface.writeAll(header_writer.buffered()) catch return;
            if (total_body_read > 0) {
                writer.interface.writeAll(body_buf[0..total_body_read]) catch return;
            }
            writer.interface.flush() catch return;
        }
    };

    const thread = try std.Thread.spawn(.{}, Context.run, .{Context{
        .server = server,
        .io = io,
    }});
    return .{ .thread = thread, .port = port };
}

test "Client: bodyReader streaming request upload (offline local)" {
    const allocator = std.testing.allocator;
    const io = std.testing.io;

    const s = try startEchoServer(io);
    defer s.thread.join();

    var client = try Self.init(allocator, io, .{ .load_ca_bundle = false });
    defer client.deinit();

    const url = try allocator.printSentinel("http://127.0.0.1:{d}/upload", .{s.port}, 0);
    defer allocator.free(url);

    const payload = "StreamedPayloadData123456789";
    var reader = std.Io.Reader.fixed(payload);

    var res = try client.post(url)
        .bodyReader(&reader, payload.len)
        .timeout(testTimeout(3000))
        .send(io);
    defer res.deinit();

    try std.testing.expectEqual(@as(u16, 200), res.status_code);
    if (res.getHeader("X-Received-Method")) |h| {
        try std.testing.expectEqualStrings("POST", h.get());
    } else {
        return error.HeaderNotFound;
    }

    const body = try res.bodyAlloc(allocator, 100);
    defer allocator.free(body);
    try std.testing.expectEqualStrings(payload, body);
}

test "Client: bodyReader error propagation (offline local)" {
    const allocator = std.testing.allocator;
    const io = std.testing.io;

    const s = try startEchoServer(io);
    defer s.thread.join();

    var client = try Self.init(allocator, io, .{ .load_ca_bundle = false });
    defer client.deinit();

    const url = try allocator.printSentinel("http://127.0.0.1:{d}/fail", .{s.port}, 0);
    defer allocator.free(url);

    var failing_buf: [16]u8 = undefined;
    var failing_reader = std.Io.Reader{
        .vtable = &.{
            .stream = struct {
                fn stream(_: *std.Io.Reader, _: *std.Io.Writer, _: std.Io.Limit) std.Io.Reader.StreamError!usize {
                    return error.ReadFailed;
                }
            }.stream,
            .readVec = struct {
                fn readVec(_: *std.Io.Reader, _: [][]u8) std.Io.Reader.Error!usize {
                    return error.ReadFailed;
                }
            }.readVec,
        },
        .buffer = &failing_buf,
        .seek = 0,
        .end = 0,
    };

    const res = client.post(url)
        .bodyReader(&failing_reader, 100)
        .timeout(testTimeout(3000))
        .send(io);

    try std.testing.expectError(error.ReadFailed, res);
}

test "Client: maxRedirects builder method works (offline local)" {
    const allocator = std.testing.allocator;
    const io = std.testing.io;

    // Initial request + 1 redirect = 2 cycles
    const s = try startRedirectLoopServer(io, 2);
    defer s.thread.join();

    var client = try Self.init(allocator, io, .{ .load_ca_bundle = false });
    defer client.deinit();

    const url = try allocator.printSentinel("http://127.0.0.1:{d}/loop", .{s.port}, 0);
    defer allocator.free(url);

    // Follows redirects but capped at 1 via fluent builder method
    const res = client.get(url)
        .maxRedirects(1)
        .timeout(testTimeout(3000))
        .send(io);

    try std.testing.expectError(error.TooManyRedirects, res);
}

test "Client: non-followed 3xx responses preserve headers (304 Not Modified & 302 without Location) (offline local)" {
    const allocator = std.testing.allocator;
    const io = std.testing.io;

    // 1. Test 304 Not Modified
    {
        const raw_304 = "HTTP/1.1 304 Not Modified\r\nETag: \"etag-12345\"\r\nCache-Control: max-age=3600\r\n\r\n";
        const s = try startMockServer(io, raw_304);
        defer s.thread.join();

        var client = try Self.init(allocator, io, .{ .load_ca_bundle = false });
        defer client.deinit();

        const url = try allocator.printSentinel("http://127.0.0.1:{d}/test304", .{s.port}, 0);
        defer allocator.free(url);

        var res = try client.get(url).timeout(testTimeout(3000)).send(io);
        defer res.deinit();

        try std.testing.expectEqual(@as(u16, 304), res.status_code);
        const etag = res.getHeader("ETag") orelse return error.HeaderMissing;
        try std.testing.expectEqualStrings("\"etag-12345\"", etag.get());
        const cc = res.getHeader("Cache-Control") orelse return error.HeaderMissing;
        try std.testing.expectEqualStrings("max-age=3600", cc.get());
    }

    // 2. Test 302 Found without Location header
    {
        const raw_302 = "HTTP/1.1 302 Found\r\nX-Custom-Notice: NoLocationProvided\r\nContent-Length: 0\r\n\r\n";
        const s = try startMockServer(io, raw_302);
        defer s.thread.join();

        var client = try Self.init(allocator, io, .{ .load_ca_bundle = false });
        defer client.deinit();

        const url = try allocator.printSentinel("http://127.0.0.1:{d}/test302", .{s.port}, 0);
        defer allocator.free(url);

        var res = try client.get(url).timeout(testTimeout(3000)).send(io);
        defer res.deinit();

        try std.testing.expectEqual(@as(u16, 302), res.status_code);
        const notice = res.getHeader("X-Custom-Notice") orelse return error.HeaderMissing;
        try std.testing.expectEqualStrings("NoLocationProvided", notice.get());
    }
}

fn startRedirectServer(io: std.Io) !struct { thread: std.Thread, port: u16 } {
    const addr = std.Io.net.IpAddress{ .ip4 = std.Io.net.Ip4Address.loopback(0) };
    var server = try addr.listen(io, .{ .mode = .stream });
    const port = server.socket.address.getPort();

    const Context = struct {
        server: std.Io.net.Server,
        io: std.Io,

        fn run(ctx: @This()) void {
            var s = ctx.server;
            defer s.deinit(ctx.io);

            var i: usize = 0;
            while (i < 2) : (i += 1) {
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

                if (i == 0) {
                    const redirect_resp = "HTTP/1.1 302 Found\r\nLocation: /final\r\nX-Intermediate-Header: true\r\nContent-Length: 0\r\nConnection: close\r\n\r\n";
                    writer.interface.writeAll(redirect_resp) catch {};
                    writer.interface.flush() catch {};
                } else {
                    const final_resp = "HTTP/1.1 200 OK\r\nX-Final-Header: true\r\nContent-Length: 5\r\nConnection: close\r\n\r\nfinal";
                    writer.interface.writeAll(final_resp) catch {};
                    writer.interface.flush() catch {};
                }
                stream.close(ctx.io);
            }
        }
    };

    const thread = try std.Thread.spawn(.{}, Context.run, .{Context{
        .server = server,
        .io = io,
    }});
    return .{ .thread = thread, .port = port };
}

test "Client: followed redirect clears intermediate headers and preserves final headers (offline local)" {
    const allocator = std.testing.allocator;
    const io = std.testing.io;

    const s = try startRedirectServer(io);
    defer s.thread.join();

    var client = try Self.init(allocator, io, .{ .load_ca_bundle = false });
    defer client.deinit();

    const url = try allocator.printSentinel("http://127.0.0.1:{d}/redirect", .{s.port}, 0);
    defer allocator.free(url);

    var res = try client.get(url).timeout(testTimeout(3000)).send(io);
    defer res.deinit();

    try std.testing.expectEqual(@as(u16, 200), res.status_code);
    // Intermediate header must NOT be present
    try std.testing.expect(res.getHeader("X-Intermediate-Header") == null);
    // Final header must be present
    const final_hdr = res.getHeader("X-Final-Header") orelse return error.HeaderMissing;
    try std.testing.expectEqualStrings("true", final_hdr.get());

    const body = try res.bodyAlloc(allocator, 100);
    defer allocator.free(body);
    try std.testing.expectEqualStrings("final", body);
}

test "Client: PUT upload with bodyReader and chunked POST without content length (offline local)" {
    const allocator = std.testing.allocator;
    const io = std.testing.io;

    var client = try Self.init(allocator, io, .{ .load_ca_bundle = false });
    defer client.deinit();

    // 1. PUT upload with bodyReader
    {
        const s = try startEchoServer(io);
        defer s.thread.join();

        const url = try allocator.printSentinel("http://127.0.0.1:{d}/put", .{s.port}, 0);
        defer allocator.free(url);

        const put_payload = "PutPayloadBytes";
        var r = std.Io.Reader.fixed(put_payload);

        var res = try client.put(url)
            .bodyReader(&r, put_payload.len)
            .timeout(testTimeout(3000))
            .send(io);
        defer res.deinit();

        try std.testing.expectEqual(@as(u16, 200), res.status_code);
        const method_hdr = res.getHeader("X-Received-Method") orelse return error.HeaderMissing;
        try std.testing.expectEqualStrings("PUT", method_hdr.get());

        const body = try res.bodyAlloc(allocator, 100);
        defer allocator.free(body);
        try std.testing.expectEqualStrings(put_payload, body);
    }

    // 2. Chunked POST upload (content_length == null)
    {
        const s = try startEchoServer(io);
        defer s.thread.join();

        const url = try allocator.printSentinel("http://127.0.0.1:{d}/chunked-post", .{s.port}, 0);
        defer allocator.free(url);

        const chunked_payload = "ChunkedPostPayloadStream";
        var r = std.Io.Reader.fixed(chunked_payload);

        var res = try client.post(url)
            .bodyReader(&r, null)
            .timeout(testTimeout(3000))
            .send(io);
        defer res.deinit();

        try std.testing.expectEqual(@as(u16, 200), res.status_code);
        const method_hdr = res.getHeader("X-Received-Method") orelse return error.HeaderMissing;
        try std.testing.expectEqualStrings("POST", method_hdr.get());

        const body = try res.bodyAlloc(allocator, 100);
        defer allocator.free(body);
        try std.testing.expectEqualStrings(chunked_payload, body);
    }
}

test "Client: RequestBuilder body and bodyReader mutual exclusivity" {
    var dummy_r = std.Io.Reader.fixed("test");
    const builder = RequestBuilder{
        .client = undefined,
        .method = .POST,
        .url = "http://example.com",
    };

    // body() followed by bodyReader()
    const b1 = builder.body("payload").bodyReader(&dummy_r, 4);
    try std.testing.expect(b1.body_data == null);
    try std.testing.expect(b1.body_reader != null);
    try std.testing.expectEqual(@as(?usize, 4), b1.body_reader_size);

    // bodyReader() followed by body()
    const b2 = builder.bodyReader(&dummy_r, 4).body("payload");
    try std.testing.expect(b2.body_reader == null);
    try std.testing.expect(b2.body_reader_size == null);
    try std.testing.expectEqualStrings("payload", b2.body_data.?);
}

test "Client: bodyReader 307 redirect fails with UploadNotRewindable (offline local)" {
    const allocator = std.testing.allocator;
    const io = std.testing.io;

    // Server responds with 307 Temporary Redirect requiring re-POST of body
    const redirect_response =
        "HTTP/1.1 307 Temporary Redirect\r\n" ++
        "Location: /redirected-target\r\n" ++
        "Content-Length: 0\r\n\r\n";

    const s = try startMockServer(io, redirect_response);
    defer s.thread.join();

    var client = try Self.init(allocator, io, .{ .load_ca_bundle = false });
    defer client.deinit();

    const url = try allocator.printSentinel("http://127.0.0.1:{d}/initial", .{s.port}, 0);
    defer allocator.free(url);

    const payload = "StreamBodyPayload";
    var r = std.Io.Reader.fixed(payload);

    // With follow_location=true, libcurl will attempt to follow 307 and re-send the streaming body.
    // Since bodyReader has no rewind capability, it must fail with error.UploadNotRewindable.
    const res = client.post(url)
        .bodyReader(&r, payload.len)
        .followLocation(true)
        .timeout(testTimeout(3000))
        .send(io);

    try std.testing.expectError(error.UploadNotRewindable, res);
}

fn startInspectServer(io: std.Io) !struct { thread: std.Thread, port: u16 } {
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

            setTestReceiveTimeout(stream);

            var read_buf: [4096]u8 = undefined;
            var reader = std.Io.net.Stream.Reader.init(stream, ctx.io, &read_buf);
            var write_buf: [4096]u8 = undefined;
            var writer = std.Io.net.Stream.Writer.init(stream, ctx.io, &write_buf);

            var http_server = std.http.Server.init(&reader.interface, &writer.interface);
            var req = http_server.receiveHead() catch return;

            var body_buf: [4096]u8 = undefined;
            var server_req_reader_buf: [1024]u8 = undefined;
            var total_body_read: usize = 0;

            var target_buf: [256]u8 = undefined;
            const target_len = @min(req.head.target.len, target_buf.len);
            @memcpy(target_buf[0..target_len], req.head.target[0..target_len]);
            const target_slice = target_buf[0..target_len];

            var ct_header_buf: [128]u8 = undefined;
            var ct_header: []const u8 = "none";
            var iter = req.iterateHeaders();
            while (iter.next()) |h| {
                if (std.ascii.eqlIgnoreCase(h.name, "Content-Type")) {
                    const copy_len = @min(h.value.len, ct_header_buf.len);
                    @memcpy(ct_header_buf[0..copy_len], h.value[0..copy_len]);
                    ct_header = ct_header_buf[0..copy_len];
                    break;
                }
            }

            if (req.head.method == .POST or req.head.method == .PUT) {
                if (req.readerExpectContinue(&server_req_reader_buf)) |req_r| {
                    while (true) {
                        const n = req_r.readSliceShort(body_buf[total_body_read..]) catch break;
                        if (n == 0) break;
                        total_body_read += n;
                        if (total_body_read == body_buf.len) break;
                    }
                } else |_| {}
            }

            var header_buf: [512]u8 = undefined;
            var header_writer = std.Io.Writer.fixed(&header_buf);
            header_writer.print("HTTP/1.1 200 OK\r\nContent-Length: {d}\r\nX-Received-Target: {s}\r\nX-Received-Content-Type: {s}\r\n\r\n", .{
                total_body_read,
                target_slice,
                ct_header,
            }) catch return;

            writer.interface.writeAll(header_writer.buffered()) catch return;
            if (total_body_read > 0) {
                writer.interface.writeAll(body_buf[0..total_body_read]) catch return;
            }
            writer.interface.flush() catch return;
        }
    };

    const thread = try std.Thread.spawn(.{}, Context.run, .{Context{
        .server = server,
        .io = io,
    }});
    return .{ .thread = thread, .port = port };
}

test "Client: RequestBuilder json serialization and Content-Type injection (offline local)" {
    const allocator = std.testing.allocator;
    const io = std.testing.io;

    const s = try startInspectServer(io);
    defer s.thread.join();

    var client = try Self.init(allocator, io, .{ .load_ca_bundle = false });
    defer client.deinit();

    const url = try allocator.printSentinel("http://127.0.0.1:{d}/api/user", .{s.port}, 0);
    defer allocator.free(url);

    const User = struct {
        name: []const u8,
        age: u32,
    };

    var req = try client.post(url)
        .json(User{ .name = "Alice", .age = 30 });
    var res = try req.timeout(testTimeout(3000)).send(io);
    defer res.deinit();

    try std.testing.expectEqual(@as(u16, 200), res.status_code);
    try std.testing.expect(res.isSuccess());
    try std.testing.expect(!res.isError());

    // Verify Content-Type was automatically injected
    const ct_hdr = res.getHeader("X-Received-Content-Type") orelse return error.HeaderMissing;
    try std.testing.expectEqualStrings("application/json", ct_hdr.get());

    // Verify body payload
    const body = try res.bodyAlloc(allocator, 1024);
    defer allocator.free(body);
    try std.testing.expectEqualStrings("{\"name\":\"Alice\",\"age\":30}", body);
}

test "Client: RequestBuilder query params with struct and slice (offline local)" {
    const allocator = std.testing.allocator;
    const io = std.testing.io;

    // 1. Test query with anonymous struct
    {
        const s = try startInspectServer(io);
        defer s.thread.join();

        var client = try Self.init(allocator, io, .{ .load_ca_bundle = false });
        defer client.deinit();

        const url = try allocator.printSentinel("http://127.0.0.1:{d}/search", .{s.port}, 0);
        defer allocator.free(url);

        var req = try client.get(url)
            .query(.{ .q = "zig & curl", .page = 2 });
        var res = try req.timeout(testTimeout(3000)).send(io);
        defer res.deinit();

        try std.testing.expectEqual(@as(u16, 200), res.status_code);
        try std.testing.expect(res.isSuccess());

        const target_hdr = res.getHeader("X-Received-Target") orelse return error.HeaderMissing;
        try std.testing.expectEqualStrings("/search?q=zig%20%26%20curl&page=2", target_hdr.get());
    }

    // 2. Test query with slice of QueryParam on an existing query URL
    {
        const s = try startInspectServer(io);
        defer s.thread.join();

        var client = try Self.init(allocator, io, .{ .load_ca_bundle = false });
        defer client.deinit();

        const url = try allocator.printSentinel("http://127.0.0.1:{d}/filter?initial=true", .{s.port}, 0);
        defer allocator.free(url);

        const params: []const QueryParam = &.{
            .{ .name = "tag", .value = "async" },
            .{ .name = "sort", .value = "desc" },
        };

        var req = try client.get(url)
            .query(params);
        var res = try req.timeout(testTimeout(3000)).send(io);
        defer res.deinit();

        try std.testing.expectEqual(@as(u16, 200), res.status_code);
        try std.testing.expect(res.isSuccess());

        const target_hdr = res.getHeader("X-Received-Target") orelse return error.HeaderMissing;
        try std.testing.expectEqualStrings("/filter?initial=true&tag=async&sort=desc", target_hdr.get());
    }
}

test "Client: Response status code helpers" {
    const dummy_response = struct {
        fn make(code: u16) Response {
            return .{
                .client = undefined,
                .status_code = code,
                .stream = null,
            };
        }
    }.make;

    const r200 = dummy_response(200);
    try std.testing.expect(r200.isSuccess());
    try std.testing.expect(!r200.isClientError());
    try std.testing.expect(!r200.isServerError());
    try std.testing.expect(!r200.isError());

    const r204 = dummy_response(204);
    try std.testing.expect(r204.isSuccess());

    const r404 = dummy_response(404);
    try std.testing.expect(!r404.isSuccess());
    try std.testing.expect(r404.isClientError());
    try std.testing.expect(!r404.isServerError());
    try std.testing.expect(r404.isError());

    const r500 = dummy_response(500);
    try std.testing.expect(!r500.isSuccess());
    try std.testing.expect(!r500.isClientError());
    try std.testing.expect(r500.isServerError());
    try std.testing.expect(r500.isError());
}
