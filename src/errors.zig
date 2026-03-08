const std = @import("std");
const assert = @import("std").debug.assert;
const c = @import("util.zig").c;

pub const HeaderError = error{
    BadIndex,
    Missing,
    NoHeaders,
    NoRequest,
    OutOfMemory,
    BadArgument,
    NotBuiltIn,

    UnknownHeaderError,
    /// This means there is no `curl_easy_header` method in current libcurl.
    NoCurlHeaderSupport,
};

pub fn headerErrorFrom(code: c.CURLHcode) ?HeaderError {
    // https://curl.se/libcurl/c/libcurl-errors.html
    return switch (code) {
        c.CURLHE_OK => null,
        c.CURLHE_BADINDEX => error.BadIndex,
        c.CURLHE_MISSING => error.Missing,
        c.CURLHE_NOHEADERS => error.NoHeaders,
        c.CURLHE_NOREQUEST => error.NoRequest,
        c.CURLHE_OUT_OF_MEMORY => error.OutOfMemory,
        c.CURLHE_BAD_ARGUMENT => error.BadArgument,
        c.CURLHE_NOT_BUILT_IN => error.NotBuiltIn,
        else => error.UnknownHeaderError,
    };
}

/// Information about the success or failure of the curl call.
pub const Diagnostics = struct {
    error_code: ?union(enum) {
        /// https://curl.se/libcurl/c/libcurl-errors.html
        code: c.CURLcode,
        /// https://curl.se/libcurl/c/libcurl-errors.html#CURLMcode
        m_code: c.CURLMcode,
    } = null,

    /// Returns a human-readable error message based on the error code.
    pub fn getMessage(self: Diagnostics) ?[]const u8 {
        const error_code = self.error_code orelse return null;
        return switch (error_code) {
            .code => |code| std.mem.span(c.curl_easy_strerror(code)),
            .m_code => |m_code| std.mem.span(c.curl_multi_strerror(m_code)),
        };
    }
};

pub fn checkCode(code: c.CURLcode, diagnostics: ?*Diagnostics) !void {
    if (code == c.CURLE_OK) {
        return;
    }

    if (diagnostics) |diag| diag.error_code = .{ .code = code };

    return error.Curl;
}

pub fn checkMCode(code: c.CURLMcode, diagnostics: ?*Diagnostics) !void {
    if (code == c.CURLM_OK) {
        return;
    }

    if (diagnostics) |diag| diag.error_code = .{ .m_code = code };

    return error.Curl;
}
