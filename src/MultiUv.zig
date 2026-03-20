//! `MultiUv` integrates libcurl's multi socket API with libuv's event loop
//! for high-performance, event-driven concurrent HTTP transfers.
//!
//! Unlike `Multi` (which uses `curl_multi_poll` — a blocking poll call),
//! `MultiUv` hooks into libuv's epoll/kqueue/IOCP-based I/O notification,
//! so the calling thread is never blocked waiting for curl sockets.
//! This is particularly useful when:
//!
//! - Hundreds or thousands of concurrent HTTP transfers are needed.
//! - HTTP transfers must share an event loop with other I/O sources.
//! - Sub-millisecond latency response to I/O readiness is required.
//!
//! ## Usage
//!
//! ```zig
//! var loop = c_uv.uv_default_loop();
//! var multi = try MultiUv.create(allocator, loop, myCallback, ctx);
//! defer multi.destroy();
//!
//! try multi.addHandle(&easy1);
//! try multi.addHandle(&easy2);
//!
//! _ = c_uv.uv_run(loop, c_uv.UV_RUN_DEFAULT); // drives the transfers
//! ```
//!
//! See: https://docs.libuv.org/en/v1.x/guide/utilities.html#external-i-o-with-polling
//! See: https://curl.se/libcurl/c/CURLMOPT_SOCKETFUNCTION.html
const std = @import("std");
const errors = @import("errors.zig");
const util = @import("util.zig");
const Easy = @import("Easy.zig");
const Multi = @import("Multi.zig");

const c = util.c;
const c_uv = @cImport({
    @cInclude("uv.h");
});

const Allocator = std.mem.Allocator;
const checkMCode = errors.checkMCode;
pub const Diagnostics = errors.Diagnostics;

const Self = @This();

/// Called once for each transfer that finishes (success or failure).
///
/// - `context`: the `on_complete_context` value passed to `create`.
/// - `handle`: the completed easy handle; use `curl_easy_getinfo` and
///   `CURLINFO_PRIVATE` to retrieve per-request state.
/// - `result`: libcurl result code (`c.CURLE_OK` == 0 means success).
pub const CompletionCallback = *const fn (
    context: ?*anyopaque,
    handle: *c.CURL,
    result: c.CURLcode,
) void;

/// Internal per-socket state: one instance per active curl socket,
/// heap-allocated so that libuv can hold a stable pointer.
const SocketContext = struct {
    poll: c_uv.uv_poll_t,
    socket: c.curl_socket_t,
    multi_uv: *Self,
};

allocator: Allocator,
loop: *c_uv.uv_loop_t,
multi: *c.CURLM,
/// Single shared timer for all curl timeouts.
timer: c_uv.uv_timer_t,
diagnostics: Diagnostics,
/// Cached value of `still_running` from the last `curl_multi_socket_action` call.
still_running: c_int,
on_complete: ?CompletionCallback,
on_complete_context: ?*anyopaque,

/// Creates a new `MultiUv` handle bound to `loop`.
///
/// The returned pointer must be released with `destroy()` **after** the
/// event loop has returned (i.e., all transfers have completed and all
/// easy handles have been removed).
///
/// `on_complete` may be `null`; if non-null it is invoked for every
/// completed transfer inside the event loop callbacks.
pub fn create(
    allocator: Allocator,
    loop: *c_uv.uv_loop_t,
    on_complete: ?CompletionCallback,
    on_complete_context: ?*anyopaque,
) !*Self {
    const self = try allocator.create(Self);
    errdefer allocator.destroy(self);

    const multi = c.curl_multi_init() orelse return error.InitMulti;
    errdefer _ = c.curl_multi_cleanup(multi);

    self.* = .{
        .allocator = allocator,
        .loop = loop,
        .multi = multi,
        .timer = undefined,
        .diagnostics = .{},
        .still_running = 0,
        .on_complete = on_complete,
        .on_complete_context = on_complete_context,
    };

    // Register the libuv timer used for curl's internal timeout.
    _ = c_uv.uv_timer_init(loop, &self.timer);
    c_uv.uv_handle_set_data(@ptrCast(&self.timer), self);

    // Tell curl to call our socket / timer callbacks instead of doing its
    // own blocking poll.
    try checkMCode(c.curl_multi_setopt(multi, c.CURLMOPT_SOCKETFUNCTION, socketCb), &self.diagnostics);
    try checkMCode(c.curl_multi_setopt(multi, c.CURLMOPT_SOCKETDATA, self), &self.diagnostics);
    try checkMCode(c.curl_multi_setopt(multi, c.CURLMOPT_TIMERFUNCTION, startTimeoutCb), &self.diagnostics);
    try checkMCode(c.curl_multi_setopt(multi, c.CURLMOPT_TIMERDATA, self), &self.diagnostics);

    return self;
}

/// Releases all resources.
///
/// Preconditions (caller responsibility):
/// - All easy handles must have been removed from the multi handle.
/// - The libuv event loop must have returned (no active callbacks).
pub fn destroy(self: *Self) void {
    _ = c_uv.uv_timer_stop(&self.timer);
    c_uv.uv_close(@ptrCast(&self.timer), null);
    // One non-blocking loop iteration processes the close callback.
    _ = c_uv.uv_run(self.loop, c_uv.UV_RUN_NOWAIT);
    _ = c.curl_multi_cleanup(self.multi);
    self.allocator.destroy(self);
}

/// Adds `easy` to this multi handle.
/// The transfer starts asynchronously once the libuv event loop runs.
pub fn addHandle(self: *Self, easy: *Easy) !void {
    try easy.setCommonOpts();
    return checkMCode(c.curl_multi_add_handle(self.multi, easy.handle), &self.diagnostics);
}

/// Removes `handle` from this multi handle.
pub fn removeHandle(self: *Self, handle: *c.CURL) !void {
    return checkMCode(c.curl_multi_remove_handle(self.multi, handle), &self.diagnostics);
}

/// Returns the number of transfers still in flight.
/// Reflects the last update from `curl_multi_socket_action`.
pub fn stillRunning(self: *const Self) c_int {
    return self.still_running;
}

// ---------------------------------------------------------------------------
// libuv timer callback — fires when curl's internal timeout expires.
// ---------------------------------------------------------------------------
fn timerCb(handle: *c_uv.uv_timer_t) callconv(.C) void {
    const data = c_uv.uv_handle_get_data(@ptrCast(handle)) orelse unreachable;
    const self: *Self = @ptrCast(@alignCast(data));
    var running: c_int = 0;
    _ = c.curl_multi_socket_action(self.multi, c.CURL_SOCKET_TIMEOUT, 0, &running);
    self.still_running = running;
    processCompletions(self);
}

// ---------------------------------------------------------------------------
// curl CURLMOPT_TIMERFUNCTION — curl requests a new timeout value.
// ---------------------------------------------------------------------------
fn startTimeoutCb(
    multi: ?*c.CURLM,
    timeout_ms: c_long,
    userp: ?*anyopaque,
) callconv(.C) c_int {
    _ = multi;
    const self: *Self = @ptrCast(@alignCast(userp.?));
    if (timeout_ms < 0) {
        // curl asks us to cancel the timer.
        _ = c_uv.uv_timer_stop(&self.timer);
    } else {
        // A timeout_ms of 0 means "fire immediately"; use 1 ms to
        // avoid a busy loop while still being effectively instant.
        const ms: u64 = if (timeout_ms == 0) 1 else @intCast(timeout_ms);
        _ = c_uv.uv_timer_start(&self.timer, timerCb, ms, 0);
    }
    return 0;
}

// ---------------------------------------------------------------------------
// libuv poll callback — a curl socket is ready for I/O.
// ---------------------------------------------------------------------------
fn pollCb(
    handle: *c_uv.uv_poll_t,
    status: c_int,
    events: c_int,
) callconv(.C) void {
    const data = c_uv.uv_handle_get_data(@ptrCast(handle)) orelse unreachable;
    const ctx: *SocketContext = @ptrCast(@alignCast(data));
    var flags: c_int = 0;
    if (status < 0) {
        // libuv reports an error on the file descriptor.
        flags = c.CURL_CSELECT_ERR;
    } else {
        if (events & c_uv.UV_READABLE != 0) flags |= c.CURL_CSELECT_IN;
        if (events & c_uv.UV_WRITABLE != 0) flags |= c.CURL_CSELECT_OUT;
    }
    _ = c.curl_multi_socket_action(
        ctx.multi_uv.multi,
        ctx.socket,
        flags,
        &ctx.multi_uv.still_running,
    );
    processCompletions(ctx.multi_uv);
}

// ---------------------------------------------------------------------------
// libuv close callback — socket poll handle has been fully closed;
// free the heap-allocated SocketContext.
// ---------------------------------------------------------------------------
fn pollCloseCb(handle: *c_uv.uv_handle_t) callconv(.C) void {
    const data = c_uv.uv_handle_get_data(handle) orelse unreachable;
    const ctx: *SocketContext = @ptrCast(@alignCast(data));
    ctx.multi_uv.allocator.destroy(ctx);
}

// ---------------------------------------------------------------------------
// curl CURLMOPT_SOCKETFUNCTION — curl tells us to watch/stop watching a socket.
// ---------------------------------------------------------------------------
fn socketCb(
    easy: ?*c.CURL,
    s: c.curl_socket_t,
    action: c_int,
    userp: ?*anyopaque,
    socketp: ?*anyopaque,
) callconv(.C) c_int {
    _ = easy;
    const self: *Self = @ptrCast(@alignCast(userp.?));

    if (action == c.CURL_POLL_REMOVE) {
        if (socketp) |ptr| {
            const ctx: *SocketContext = @ptrCast(@alignCast(ptr));
            _ = c_uv.uv_poll_stop(&ctx.poll);
            // Close is async; pollCloseCb frees ctx after the handle is closed.
            c_uv.uv_close(@ptrCast(&ctx.poll), pollCloseCb);
            _ = c.curl_multi_assign(self.multi, s, null);
        }
        return 0;
    }

    // Build the libuv event mask from the curl action.
    var events: c_int = 0;
    if (action == c.CURL_POLL_IN or action == c.CURL_POLL_INOUT) events |= c_uv.UV_READABLE;
    if (action == c.CURL_POLL_OUT or action == c.CURL_POLL_INOUT) events |= c_uv.UV_WRITABLE;

    if (socketp) |ptr| {
        // Already have a poll handle; just update its event mask.
        const ctx: *SocketContext = @ptrCast(@alignCast(ptr));
        _ = c_uv.uv_poll_start(&ctx.poll, events, pollCb);
    } else {
        // First time we see this socket: allocate a context and create a poll handle.
        const ctx = self.allocator.create(SocketContext) catch return -1;
        ctx.* = .{
            .poll = undefined,
            .socket = s,
            .multi_uv = self,
        };
        if (c_uv.uv_poll_init_socket(self.loop, &ctx.poll, s) != 0) {
            self.allocator.destroy(ctx);
            return -1;
        }
        c_uv.uv_handle_set_data(@ptrCast(&ctx.poll), ctx);
        _ = c_uv.uv_poll_start(&ctx.poll, events, pollCb);
        _ = c.curl_multi_assign(self.multi, s, ctx);
    }
    return 0;
}

// ---------------------------------------------------------------------------
// Internal helper: drain curl's info queue and invoke on_complete.
// ---------------------------------------------------------------------------
fn processCompletions(self: *Self) void {
    var msgs_in_queue: c_int = undefined;
    while (c.curl_multi_info_read(self.multi, &msgs_in_queue)) |msg| {
        if (msg.msg == c.CURLMSG_DONE) {
            const handle = msg.easy_handle.?;
            const result = msg.data.result;
            // Remove handle from multi *before* invoking the callback so
            // that the callback may safely add new handles.
            _ = c.curl_multi_remove_handle(self.multi, handle);
            if (self.on_complete) |cb| {
                cb(self.on_complete_context, handle, result);
            }
        }
    }
}
