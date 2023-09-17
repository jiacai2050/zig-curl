const c = @import("c.zig").c;
const assert = @import("std").debug.assert;

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
