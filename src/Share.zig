//! `Share` provides a safe Zig wrapper around libcurl's Shared Interface (`CURLSH`).
//!
//! It enables multiple easy handles to share data such as:
//! - Connection cache (Keep-Alive TCP connection reuse)
//! - DNS resolution cache
//! - TLS/SSL session ID cache
//!
//! https://curl.se/libcurl/c/libcurl-share.html
const std = @import("std");
const errors = @import("errors.zig");
const util = @import("util.zig");
const c = util.c;

const Allocator = std.mem.Allocator;
const assert = std.debug.assert;
const checkSHCode = errors.checkSHCode;
pub const Diagnostics = errors.Diagnostics;
const Self = @This();

/// Number of lockable resources supported by libcurl.
const lock_data_count = @as(usize, @intCast(c.CURL_LOCK_DATA_LAST));

pub const SpinLock = struct {
    state: std.atomic.Value(bool) = std.atomic.Value(bool).init(false),

    pub fn lock(self: *SpinLock) void {
        while (self.state.swap(true, .acquire)) {
            while (self.state.load(.monotonic)) {
                std.atomic.spinLoopHint();
            }
        }
    }

    pub fn unlock(self: *SpinLock) void {
        self.state.store(false, .release);
    }
};

allocator: Allocator,
handle: *c.CURLSH,
diagnostics: Diagnostics,
/// Dedicated spinlocks for each lockable resource type to minimize lock contention.
/// libcurl only holds these locks for brief in-memory lookups.
mutexes: [lock_data_count]SpinLock,

pub const Options = struct {
    share_dns: bool = true,
    share_connect: bool = true,
    share_ssl_session: bool = true,
};

pub fn init(allocator: Allocator, options: Options) !*Self {
    const self = try allocator.create(Self);
    errdefer allocator.destroy(self);

    const core = c.curl_share_init();
    if (core == null) {
        return error.InitShareFailed;
    }
    errdefer assert(c.curl_share_cleanup(core) == c.CURLSHE_OK);

    self.* = .{
        .allocator = allocator,
        .handle = core.?,
        .diagnostics = .{},
        .mutexes = @splat(.{}),
    };

    // Configure thread-safety locking callbacks.
    try self.setopt(c.CURLSHOPT_USERDATA, self);
    try self.setopt(c.CURLSHOPT_LOCKFUNC, lockCallback);
    try self.setopt(c.CURLSHOPT_UNLOCKFUNC, unlockCallback);

    if (options.share_dns) {
        try self.setopt(c.CURLSHOPT_SHARE, @as(c_int, c.CURL_LOCK_DATA_DNS));
    }
    if (options.share_connect) {
        try self.setopt(c.CURLSHOPT_SHARE, @as(c_int, c.CURL_LOCK_DATA_CONNECT));
    }
    if (options.share_ssl_session) {
        try self.setopt(c.CURLSHOPT_SHARE, @as(c_int, c.CURL_LOCK_DATA_SSL_SESSION));
    }

    return self;
}

pub fn deinit(self: *Self) void {
    const rc = c.curl_share_cleanup(self.handle);
    assert(rc == c.CURLSHE_OK);
    const allocator = self.allocator;
    allocator.destroy(self);
}

fn setopt(self: *Self, option: c_uint, param: anytype) !void {
    return checkSHCode(c.curl_share_setopt(self.handle, option, param), &self.diagnostics);
}

fn lockCallback(
    curl_handle: ?*c.CURL,
    data: c.curl_lock_data,
    access: c.curl_lock_access,
    userptr: ?*anyopaque,
) callconv(.c) void {
    _ = curl_handle;
    _ = access;
    assert(userptr != null);
    const self: *Self = @ptrCast(@alignCast(userptr.?));

    const index = @as(usize, @intCast(data));
    assert(index < lock_data_count);
    self.mutexes[index].lock();
}

fn unlockCallback(
    curl_handle: ?*c.CURL,
    data: c.curl_lock_data,
    userptr: ?*anyopaque,
) callconv(.c) void {
    _ = curl_handle;
    assert(userptr != null);
    const self: *Self = @ptrCast(@alignCast(userptr.?));

    const index = @as(usize, @intCast(data));
    assert(index < lock_data_count);
    self.mutexes[index].unlock();
}

test "Share: init and deinit lifecycle" {
    // Verifies that a Share handle can be initialized with custom options
    // and cleaned up without leaking memory or resources.
    const share = try Self.init(std.testing.allocator, .{
        .share_dns = true,
        .share_connect = true,
        .share_ssl_session = true,
    });
    defer share.deinit();

    // Verify handle is non-null
    assert(@intFromPtr(share.handle) != 0);
}
