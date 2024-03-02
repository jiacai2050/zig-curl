const std = @import("std");
const util = @import("util.zig");
const checkCode = @import("errors.zig").checkCode;

pub const Easy = @import("Easy.zig");
pub const Multi = @import("Multi.zig");
pub const bufferWriteCallback = Easy.bufferWriteCallback;
pub const printLibcurlVersion = util.printLibcurlVersion;
pub const urlEncode = util.urlEncode;
pub const allocCABundle = util.allocCABundle;
pub const Buffer = util.Buffer;
pub const libcurl = util.c;

/// This function sets up the program environment that libcurl needs.
/// Since this function is not thread safe before libcurl 7.84.0, this function
/// must be called before the program calls any other function in libcurl.
/// A common place is in the beginning of the program. More see:
/// https://curl.se/libcurl/c/curl_global_init.html
pub fn global_init() !void {
    try checkCode(libcurl.curl_global_init(libcurl.CURL_GLOBAL_ALL));
}

/// This function releases resources acquired by curl_global_init.
pub fn global_deinit() void {
    libcurl.curl_global_cleanup();
}

test {
    std.testing.refAllDecls(@This());
}
