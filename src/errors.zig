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
        /// https://curl.se/libcurl/c/libcurl-errors.html#CURLSHcode
        sh_code: c.CURLSHcode,
    } = null,

    /// Returns a human-readable error message based on the error code.
    pub fn getMessage(self: Diagnostics) ?[]const u8 {
        const error_code = self.error_code orelse return null;
        return switch (error_code) {
            .code => |code| std.mem.span(c.curl_easy_strerror(code)),
            .m_code => |m_code| std.mem.span(c.curl_multi_strerror(m_code)),
            .sh_code => |sh_code| std.mem.span(c.curl_share_strerror(sh_code)),
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

pub const HttpError = error{
    Timeout,
    NameResolutionFailed,
    ConnectionFailed,
    ConnectionReset,
    TlsHandshakeFailed,
    CertificateVerificationFailed,
    TooManyRedirects,
    HttpConnectionClosed,
    HttpTransferFailed,
    CurlAborted,
    ClientClosed,
    OutOfMemory,
    UploadNotRewindable,
};

pub fn httpErrorFrom(code: c.CURLcode) HttpError {
    assert(code != c.CURLE_OK);
    return switch (code) {
        c.CURLE_OPERATION_TIMEDOUT => error.Timeout,
        c.CURLE_COULDNT_RESOLVE_HOST, c.CURLE_COULDNT_RESOLVE_PROXY => error.NameResolutionFailed,
        c.CURLE_COULDNT_CONNECT => error.ConnectionFailed,
        c.CURLE_SSL_CONNECT_ERROR => error.TlsHandshakeFailed,
        c.CURLE_PEER_FAILED_VERIFICATION => error.CertificateVerificationFailed,
        c.CURLE_TOO_MANY_REDIRECTS => error.TooManyRedirects,
        c.CURLE_GOT_NOTHING => error.HttpConnectionClosed,
        c.CURLE_PARTIAL_FILE => error.HttpTransferFailed,
        c.CURLE_RECV_ERROR, c.CURLE_SEND_ERROR => error.ConnectionReset,
        c.CURLE_ABORTED_BY_CALLBACK => error.CurlAborted,
        c.CURLE_OUT_OF_MEMORY => error.OutOfMemory,
        c.CURLE_SEND_FAIL_REWIND => error.UploadNotRewindable,
        else => error.HttpTransferFailed,
    };
}

pub fn checkMCode(code: c.CURLMcode, diagnostics: ?*Diagnostics) !void {
    if (code == c.CURLM_OK) {
        return;
    }

    if (diagnostics) |diag| diag.error_code = .{ .m_code = code };

    return error.Curl;
}

pub fn checkSHCode(code: c.CURLSHcode, diagnostics: ?*Diagnostics) !void {
    if (code == c.CURLSHE_OK) {
        return;
    }

    if (diagnostics) |diag| diag.error_code = .{ .sh_code = code };

    return error.Curl;
}

test "errors: httpErrorFrom mapping table" {
    const testing = std.testing;
    try testing.expectEqual(error.Timeout, httpErrorFrom(c.CURLE_OPERATION_TIMEDOUT));
    try testing.expectEqual(error.NameResolutionFailed, httpErrorFrom(c.CURLE_COULDNT_RESOLVE_HOST));
    try testing.expectEqual(error.NameResolutionFailed, httpErrorFrom(c.CURLE_COULDNT_RESOLVE_PROXY));
    try testing.expectEqual(error.ConnectionFailed, httpErrorFrom(c.CURLE_COULDNT_CONNECT));
    try testing.expectEqual(error.TlsHandshakeFailed, httpErrorFrom(c.CURLE_SSL_CONNECT_ERROR));
    try testing.expectEqual(error.CertificateVerificationFailed, httpErrorFrom(c.CURLE_PEER_FAILED_VERIFICATION));
    try testing.expectEqual(error.TooManyRedirects, httpErrorFrom(c.CURLE_TOO_MANY_REDIRECTS));
    try testing.expectEqual(error.HttpConnectionClosed, httpErrorFrom(c.CURLE_GOT_NOTHING));
    try testing.expectEqual(error.HttpTransferFailed, httpErrorFrom(c.CURLE_PARTIAL_FILE));
    try testing.expectEqual(error.ConnectionReset, httpErrorFrom(c.CURLE_RECV_ERROR));
    try testing.expectEqual(error.ConnectionReset, httpErrorFrom(c.CURLE_SEND_ERROR));
    try testing.expectEqual(error.CurlAborted, httpErrorFrom(c.CURLE_ABORTED_BY_CALLBACK));
    try testing.expectEqual(error.OutOfMemory, httpErrorFrom(c.CURLE_OUT_OF_MEMORY));
    try testing.expectEqual(error.HttpTransferFailed, httpErrorFrom(c.CURLE_BAD_FUNCTION_ARGUMENT));
}
