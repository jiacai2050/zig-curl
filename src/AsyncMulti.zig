//! Event-loop adapter for driving libcurl's multi-socket interface without blocking.
const std = @import("std");
const Multi = @import("Multi.zig");
const errors = @import("errors.zig");
const util = @import("util.zig");

const c = util.c;
const checkMCode = errors.checkMCode;

pub const SocketInterest = enum {
    none,
    read,
    write,
    read_write,
    remove,
};

/// These callbacks must only update or enqueue event-loop registrations.
/// They must not block or call back into this AsyncMulti.
pub const Hooks = struct {
    context: *anyopaque,
    update_socket: *const fn (
        context: *anyopaque,
        socket: c.curl_socket_t,
        interest: SocketInterest,
    ) callconv(.c) c_int,
    update_timer: *const fn (
        context: *anyopaque,
        timeout_ms: c_long,
    ) callconv(.c) c_int,
};

const Self = @This();

multi: Multi,
hooks: *const Hooks,

/// The hooks pointer must remain valid and at a stable address until deinit.
pub fn init(hooks: *const Hooks) !Self {
    var multi = try Multi.init();
    errdefer multi.deinit() catch {};

    try checkMCode(
        c.curl_multi_setopt(multi.multi, c.CURLMOPT_SOCKETFUNCTION, socketCallback),
        &multi.diagnostics,
    );
    try checkMCode(
        c.curl_multi_setopt(multi.multi, c.CURLMOPT_SOCKETDATA, hooks),
        &multi.diagnostics,
    );
    try checkMCode(
        c.curl_multi_setopt(multi.multi, c.CURLMOPT_TIMERFUNCTION, timerCallback),
        &multi.diagnostics,
    );
    try checkMCode(
        c.curl_multi_setopt(multi.multi, c.CURLMOPT_TIMERDATA, hooks),
        &multi.diagnostics,
    );

    return .{
        .multi = multi,
        .hooks = hooks,
    };
}

pub fn deinit(self: *Self) !void {
    return self.multi.deinit();
}

pub fn addHandle(self: *Self, easy: anytype) !void {
    return self.multi.addHandle(easy);
}

pub fn removeHandle(self: *Self, handle: *c.CURL) !void {
    return self.multi.removeHandle(handle);
}

/// Notify libcurl that a registered socket became ready.
pub fn socketReady(
    self: *Self,
    socket: c.curl_socket_t,
    readable: bool,
    writable: bool,
    failed: bool,
) !c_int {
    const flags: c_int =
        (if (readable) c.CURL_CSELECT_IN else 0) |
        (if (writable) c.CURL_CSELECT_OUT else 0) |
        (if (failed) c.CURL_CSELECT_ERR else 0);
    return self.socketAction(socket, flags);
}

/// Notify libcurl that its current timer expired.
pub fn timerExpired(self: *Self) !c_int {
    return self.socketAction(c.CURL_SOCKET_TIMEOUT, 0);
}

/// Advance curl after a socket or timer event. Returns the number of active transfers.
pub fn socketAction(self: *Self, socket: c.curl_socket_t, flags: c_int) !c_int {
    var still_running: c_int = undefined;
    try checkMCode(
        c.curl_multi_socket_action(self.multi.multi, socket, flags, &still_running),
        &self.multi.diagnostics,
    );
    return still_running;
}

pub fn readInfo(self: *Self) !Multi.Info {
    return self.multi.readInfo();
}

pub fn diagnostics(self: *Self) *errors.Diagnostics {
    return &self.multi.diagnostics;
}

fn socketCallback(
    _: ?*c.CURL,
    socket: c.curl_socket_t,
    what: c_int,
    user_data: ?*anyopaque,
    _: ?*anyopaque,
) callconv(.c) c_int {
    const hooks: *const Hooks = @ptrCast(@alignCast(user_data orelse return -1));
    const interest: SocketInterest = switch (what) {
        c.CURL_POLL_NONE => .none,
        c.CURL_POLL_IN => .read,
        c.CURL_POLL_OUT => .write,
        c.CURL_POLL_INOUT => .read_write,
        c.CURL_POLL_REMOVE => .remove,
        else => return -1,
    };
    return hooks.update_socket(hooks.context, socket, interest);
}

fn timerCallback(
    _: ?*c.CURLM,
    timeout_ms: c_long,
    user_data: ?*anyopaque,
) callconv(.c) c_int {
    const hooks: *const Hooks = @ptrCast(@alignCast(user_data orelse return -1));
    return hooks.update_timer(hooks.context, timeout_ms);
}
