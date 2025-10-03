//! ![zig curl logo](https://raw.githubusercontent.com/jiacai2050/zig-curl/main/docs/logo.svg)
//!
//! [Zig-curl](https://github.com/jiacai2050/zig-curl) is a Zig binding for libcurl, a free and easy-to-use client-side URL transfer library.
//!
//! It provides a safe and idiomatic Zig interface to perform HTTP requests, handle responses,
//! and manage connections.
const std = @import("std");
const util = @import("util.zig");
pub const checkCode = @import("errors.zig").checkCode;

pub const Easy = @import("Easy.zig");
pub const Multi = @import("Multi.zig");
pub const MultiPart = @import("MultiPart.zig");

pub const printLibcurlVersion = util.printLibcurlVersion;
pub const hasParseHeaderSupport = util.hasParseHeaderSupport;
pub const urlEncode = util.urlEncode;
pub const allocCABundle = util.allocCABundle;
/// Expose the raw libcurl C bindings for advanced use cases.
pub const libcurl = util.c;

/// This function sets up the program environment that libcurl needs.
/// Since this function is not thread safe before libcurl 7.84.0, this function
/// must be called before the program calls any other function in libcurl.
/// A common place is in the beginning of the program. More see:
/// https://curl.se/libcurl/c/curl_global_init.html
pub fn globalInit() !void {
    try checkCode(libcurl.curl_global_init(libcurl.CURL_GLOBAL_ALL));
}

/// This function releases resources acquired by curl_global_init.
pub fn globalDeinit() void {
    libcurl.curl_global_cleanup();
}

test {
    std.testing.refAllDecls(@This());
}
