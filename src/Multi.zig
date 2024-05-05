const std = @import("std");
const errors = @import("errors.zig");
const util = @import("util.zig");
const Easy = @import("Easy.zig");
const c = util.c;

const mem = std.mem;
const fmt = std.fmt;
const Allocator = mem.Allocator;
const checkMCode = errors.checkMCode;
const Self = @This();

multi: *c.CURLM,

pub fn init() !Self {
    const core = c.curl_multi_init();
    if (core == null) {
        return error.InitMulti;
    }
    return .{ .multi = core.? };
}

pub fn deinit(self: Self) void {
    _ = self;
}

/// Adds the easy handle to the multi_handle.
/// https://curl.se/libcurl/c/curl_multi_add_handle.html
pub fn addHandle(self: Self, easy: Easy) !void {
    try easy.setCommonOpts();
    return checkMCode(c.curl_multi_add_handle(self.multi, easy.handle));
}

/// Removes a given easy_handle from the multi_handle.
/// https://curl.se/libcurl/c/curl_multi_remove_handle.html
pub fn removeHandle(self: Self, handle: *c.CURL) !void {
    return checkMCode(c.curl_multi_remove_handle(self.multi, handle));
}

/// Performs transfers on all the added handles that need attention in a non-blocking fashion.
/// Returns the number of handles that still transfer data. When that reaches zero, all transfers are done.
/// https://curl.se/libcurl/c/curl_multi_perform.html
pub fn perform(self: Self) !c_int {
    var still_running: c_int = undefined;
    try checkMCode(c.curl_multi_perform(self.multi, &still_running));

    return still_running;
}

/// Polls all file descriptors used by the curl easy handles contained in the given multi handle set.
/// Return the number of file descriptors on which there is activity.
/// https://curl.se/libcurl/c/curl_multi_poll.html
pub fn poll(self: Self, extra_fds: ?[]c.curl_waitfd, timeout_ms: c_int) !c_int {
    var num_fds: c_int = undefined;
    var fds: ?[*]c.curl_waitfd = null;
    var fd_len: c_uint = 0;
    if (extra_fds) |v| {
        fds = v.ptr;
        fd_len = @intCast(v.len);
    }

    try checkMCode(c.curl_multi_poll(self.multi, fds, fd_len, timeout_ms, &num_fds));
    return num_fds;
}

/// Wakes up a sleeping curl_multi_poll call that is currently (or is about to be) waiting for activity or a timeout.
/// This function can be called from any thread.
/// https://curl.se/libcurl/c/curl_multi_wakeup.html
pub fn wakeup(self: Self) !void {
    try checkMCode(c.curl_multi_wakeup(self.multi));
}

pub const Info = struct {
    msgs_in_queue: c_int,
    msg: *c.CURLMsg,
};

/// Ask the multi handle if there are any messages from the individual transfers.
/// https://curl.se/libcurl/c/curl_multi_info_read.html
pub fn readInfo(self: Self) !Info {
    var msgs_in_queue: c_int = undefined;

    const msg = c.curl_multi_info_read(self.multi, &msgs_in_queue);
    if (msg == null) {
        return error.InfoReadExhausted;
    }

    return Info{
        .msg = msg.?,
        .msgs_in_queue = msgs_in_queue,
    };
}
