const std = @import("std");
const errors = @import("errors.zig");
const util = @import("util.zig");
const Easy = @import("easy.zig");
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

pub fn deinit() void {}

/// Adds the easy handle to the multi_handle.
/// https://curl.se/libcurl/c/curl_multi_add_handle.html
pub fn addHandle(self: Self, handle: *c.CURL) !void {
    return checkMCode(c.curl_multi_add_handle(self.multi, handle));
}

/// Removes a given easy_handle from the multi_handle.
/// https://curl.se/libcurl/c/curl_multi_remove_handle.html
pub fn removeHandle(self: Self, handle: *c.CURL) !void {
    return checkMCode(c.curl_multi_remove_handle(self.multi, handle));
}

/// This function performs transfers on all the added handles that need attention in a non-blocking fashion.
/// Returns the number of handles that still transfer data. When that reaches zero, all transfers are done.
/// https://curl.se/libcurl/c/curl_multi_perform.html
pub fn perform(self: Self) !c_int {
    var still_running: c_int = undefined;
    try checkMCode(c.curl_multi_perform(self.multi, &still_running));

    return still_running;
}

const Info = struct {
    msgs_in_queue: c_int,
    msg: *c.CURLMsg,
};

pub fn readInfo(self: Self) !Info {
    var msgs_in_queue: c_int = undefined;

    const msg = c.curl_multi_info_read(self.multi, &msgs_in_queue);
    if (msg == null) {
        return error.OutOfStruct;
    }

    return Info{
        .msg = msg.?,
        .msgs_in_queue = msgs_in_queue,
    };
}
