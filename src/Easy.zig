const std = @import("std");
const errors = @import("errors.zig");
const util = @import("util.zig");
const MultiPart = @import("MultiPart.zig");

const mem = std.mem;
const fmt = std.fmt;
const Writer = std.Io.Writer;
const Reader = std.Io.Reader;
const Allocator = mem.Allocator;
const checkCode = errors.checkCode;
const c = util.c;
const ResizableBuffer = util.ResizableBuffer;

const hasParseHeaderSupport = @import("util.zig").hasParseHeaderSupport;

const Self = @This();

handle: *c.CURL,
timeout_ms: usize,
user_agent: [:0]const u8,
ca_bundle: ?ResizableBuffer,

pub const HttpVersion = enum(c_long) {
    none = c.CURL_HTTP_VERSION_NONE,
    http1_0 = c.CURL_HTTP_VERSION_1_0,
    http1_1 = c.CURL_HTTP_VERSION_1_1,
    http2 = c.CURL_HTTP_VERSION_2_0,
    http2_tls = c.CURL_HTTP_VERSION_2TLS,
    http2_prior_knowledge = c.CURL_HTTP_VERSION_2_PRIOR_KNOWLEDGE,
    http3 = c.CURL_HTTP_VERSION_3,
    http3_only = c.CURL_HTTP_VERSION_3ONLY,
};

pub const Method = enum {
    GET,
    POST,
    PUT,
    HEAD,
    PATCH,
    DELETE,

    fn asString(self: Method) [:0]const u8 {
        return @tagName(self);
    }
};

pub const Headers = struct {
    headers: ?*c.struct_curl_slist = null,

    pub fn deinit(self: Headers) void {
        if (self.headers) |h| {
            c.curl_slist_free_all(h);
        }
    }

    /// `header` is in `name: value` format.
    pub fn add(self: *Headers, header: [:0]const u8) !void {
        self.headers = c.curl_slist_append(self.headers, header.ptr) orelse {
            return errors.HeaderError.OutOfMemory;
        };
    }
};

pub const FetchOptions = struct {
    method: Method = .GET,
    body: ?[]const u8 = null,
    headers: ?[]const [:0]const u8 = null,
    /// If the server sends a body, it will be written here.
    writer: ?*Writer = null,
};

pub const Response = struct {
    status_code: i32,

    handle: *c.CURL,

    fn polyfill_struct_curl_header() type {
        if (hasParseHeaderSupport()) {
            return c.struct_curl_header;
        } else {
            // return a dummy struct to make it compile on old version.
            return struct {
                value: [:0]const u8,
            };
        }
    }

    pub const Header = struct {
        c_header: *polyfill_struct_curl_header(),
        name: []const u8,

        /// Get the first value associated with the given key.
        /// Applications need to copy the data if it wants to keep it around.
        pub fn get(self: Header) []const u8 {
            return mem.sliceTo(self.c_header.value, 0);
        }
    };

    /// Gets the header associated with the given name.
    pub fn getHeader(self: Response, name: [:0]const u8) errors.HeaderError!?Header {
        if (comptime !hasParseHeaderSupport()) {
            return error.NoCurlHeaderSupport;
        }

        var header: ?*c.struct_curl_header = null;
        return Response.getHeaderInner(
            self.handle,
            name,
            -1, // request, -1 means last request
            &header,
        );
    }

    fn getHeaderInner(easy: ?*c.CURL, name: [:0]const u8, request: c_int, hout: *?*c.struct_curl_header) errors.HeaderError!?Header {
        const code = c.curl_easy_header(
            easy,
            name.ptr,
            0, // index, 0 means first header
            c.CURLH_HEADER,
            request,
            hout,
        );
        return if (errors.headerErrorFrom(code)) |err| switch (err) {
            error.Missing, error.NoHeaders => null,
            else => err,
        } else .{
            .c_header = hout.*.?,
            .name = name,
        };
    }

    pub const HeaderIterator = struct {
        handle: *c.CURL,
        name: ?[:0]const u8,
        request: ?usize,
        c_header: ?*polyfill_struct_curl_header() = null,

        pub fn next(self: *HeaderIterator) !?Header {
            if (comptime !hasParseHeaderSupport()) {
                return error.NoCurlHeaderSupport;
            }

            const request: c_int = if (self.request) |v| @intCast(v) else -1;

            if (self.name) |filter_name| {
                if (self.c_header) |c_header| {
                    // fast path
                    if (c_header.*.index + 1 == c_header.*.amount) {
                        return null;
                    }
                } else {
                    return Response.getHeaderInner(self.handle, filter_name, request, &self.c_header);
                }
            }

            while (c.curl_easy_nextheader(
                self.handle,
                c.CURLH_HEADER,
                request,
                self.c_header,
            )) |c_header| {
                self.c_header = c_header;

                const name = std.mem.sliceTo(c_header.*.name, 0);
                if (self.name) |filter_name| {
                    if (!std.ascii.eqlIgnoreCase(name, filter_name)) {
                        continue;
                    }
                }

                return Header{
                    .c_header = c_header,
                    .name = name,
                };
            } else {
                return null;
            }
        }
    };

    pub const IterateHeadersOptions = struct {
        /// Only iterate over headers matching a specific name.
        name: ?[:0]const u8 = null,
        /// Which request you want headers from. Useful when there are redirections.
        /// Leaving `null` means the last request.
        request: ?usize = null,
    };

    pub fn iterateHeaders(self: Response, options: IterateHeadersOptions) errors.HeaderError!HeaderIterator {
        if (comptime !hasParseHeaderSupport()) {
            return error.NoCurlHeaderSupport;
        }

        return HeaderIterator{
            .handle = self.handle,
            .name = options.name,
            .request = options.request,
        };
    }

    pub fn getRedirectCount(self: Response) !usize {
        var redirects: c_long = undefined;
        try checkCode(c.curl_easy_getinfo(self.handle, c.CURLINFO_REDIRECT_COUNT, &redirects));
        return @intCast(redirects);
    }
};

pub const Upload = struct {
    reader: *Reader,

    pub fn init(reader: *Reader) !Upload {
        return .{ .reader = reader };
    }

    pub fn readFunction(ptr: [*c]c_char, size: c_uint, nmemb: c_uint, user_data: ?*anyopaque) callconv(.c) c_uint {
        const up: *Upload = @ptrCast(@alignCast(user_data orelse return c.CURL_READFUNC_ABORT));
        const max_length: usize = @intCast(size * nmemb);
        var buf: [*]u8 = @ptrCast(ptr);
        const n = up.reader.readSliceShort(buf[0..max_length]) catch |e| {
            std.log.err("Upload read file failed, err:{any}\n", .{e});
            return c.CURL_READFUNC_ABORT;
        };

        return @intCast(n);
    }
};

/// Init options for Easy handle
pub const Options = struct {
    // Note that the vendored libcurl is compiled with mbedtls and does not include a CA bundle,
    // so this should be set when link with vendored libcurl, otherwise https
    // requests will fail.
    ca_bundle: ?ResizableBuffer = null,
    /// The maximum time in milliseconds that the entire transfer operation to take.
    default_timeout_ms: usize = 30_000,
    default_user_agent: [:0]const u8 = "zig-curl/" ++ @import("build_info").version,
};

pub fn init(options: Options) !Self {
    return if (c.curl_easy_init()) |handle|
        .{
            .handle = handle,
            .ca_bundle = options.ca_bundle,
            .timeout_ms = options.default_timeout_ms,
            .user_agent = options.default_user_agent,
        }
    else
        error.CurlInit;
}

pub fn deinit(self: Self) void {
    c.curl_easy_cleanup(self.handle);
}

pub fn createMultiPart(self: Self) !MultiPart {
    return MultiPart.init(self);
}

pub fn setUrl(self: Self, url: [:0]const u8) !void {
    try checkCode(c.curl_easy_setopt(self.handle, c.CURLOPT_URL, url.ptr));
}

pub fn setMaxRedirects(self: Self, redirects: u32) !void {
    try checkCode(c.curl_easy_setopt(self.handle, c.CURLOPT_MAXREDIRS, @as(c_long, redirects)));
}

pub fn setMethod(self: Self, method: Method) !void {
    try checkCode(c.curl_easy_setopt(self.handle, c.CURLOPT_CUSTOMREQUEST, method.asString().ptr));
}

pub fn setVerbose(self: Self, verbose: bool) !void {
    try checkCode(c.curl_easy_setopt(self.handle, c.CURLOPT_VERBOSE, verbose));
}

pub fn setPostFields(self: Self, body: []const u8) !void {
    try checkCode(c.curl_easy_setopt(self.handle, c.CURLOPT_POSTFIELDS, body.ptr));
    try checkCode(c.curl_easy_setopt(self.handle, c.CURLOPT_POSTFIELDSIZE, body.len));
}

pub fn setMultiPart(self: Self, multi_part: MultiPart) !void {
    try checkCode(c.curl_easy_setopt(self.handle, c.CURLOPT_MIMEPOST, multi_part.mime_handle));
}

pub fn setUpload(self: Self, up: *Upload) !void {
    try checkCode(c.curl_easy_setopt(self.handle, c.CURLOPT_UPLOAD, @as(c_int, 1)));
    try checkCode(c.curl_easy_setopt(self.handle, c.CURLOPT_READFUNCTION, Upload.readFunction));
    try checkCode(c.curl_easy_setopt(self.handle, c.CURLOPT_READDATA, up));
}

/// Ask libcurl to use the specific HTTP versions.
/// Note that the HTTP version is just a request. libcurl still prioritizes to reuse existing connections
/// so it might then reuse a connection using an HTTP version you have not asked for.
///
/// https://curl.se/libcurl/c/CURLOPT_HTTP_VERSION.html
pub fn setHttpVersion(self: Self, version: HttpVersion) !void {
    try checkCode(c.curl_easy_setopt(
        self.handle,
        c.CURLOPT_HTTP_VERSION,
        @intFromEnum(version),
    ));
}

pub fn setFollowLocation(self: Self, enable: bool) !void {
    const param: c_long = @intCast(@intFromBool(enable));
    try checkCode(c.curl_easy_setopt(self.handle, c.CURLOPT_FOLLOWLOCATION, param));
}

pub fn reset(self: Self) void {
    c.curl_easy_reset(self.handle);
}

pub fn setHeaders(self: Self, headers: Headers) !void {
    if (headers.headers) |c_headers| {
        try self.setHeadersC(c_headers);
    }
}

pub fn setHeadersC(self: Self, headers: *c.struct_curl_slist) !void {
    try checkCode(c.curl_easy_setopt(self.handle, c.CURLOPT_HTTPHEADER, headers));
}

pub fn setUnixSocketPath(self: Self, path: [:0]const u8) !void {
    try checkCode(c.curl_easy_setopt(self.handle, c.CURLOPT_UNIX_SOCKET_PATH, path.ptr));
}

pub fn setPrivate(self: Self, data: *const anyopaque) !void {
    try checkCode(c.curl_easy_setopt(self.handle, c.CURLOPT_PRIVATE, data));
}

pub fn setWritedata(self: Self, data: *anyopaque) !void {
    try checkCode(c.curl_easy_setopt(self.handle, c.CURLOPT_WRITEDATA, data));
}

/// Set a write function that will be called with the response body.
/// The function should return the number of bytes written, or 0 to indicate an error.
/// There are two write functions provided by this library:
/// 1. `discardWriteCallback` - does nothing, used when you don't care about the response body.
/// 2. `stdoutWriteCallback` - writes the response body to stdout.
///
/// https://curl.se/libcurl/c/CURLOPT_WRITEFUNCTION.html
pub fn setWritefunction(
    self: Self,
    func: *const fn ([*c]c_char, c_uint, c_uint, *anyopaque) callconv(.c) c_uint,
) !void {
    try checkCode(c.curl_easy_setopt(self.handle, c.CURLOPT_WRITEFUNCTION, func));
}

/// Set `WRITEDATA` to `Writer` and `WRITEFUNCTION` to a function that calls with the writer.
pub fn setWriter(
    self: Self,
    writer: *Writer,
) !void {
    try self.setWritedata(writer);
    try self.setWritefunction(struct {
        fn write(ptr: [*c]c_char, size: c_uint, nmemb: c_uint, user_data: ?*anyopaque) callconv(.c) c_uint {
            const real_size = size * nmemb;
            const data = (@as([*]const u8, @ptrCast(ptr)))[0..real_size];
            const writer_inner: *Writer = @ptrCast(@alignCast(user_data orelse return 0));
            writer_inner.writeAll(data) catch {
                return 0; // Indicate an error
            };
            return @intCast(real_size);
        }
    }.write);
}

pub fn setDebugdata(self: Self, data: *const anyopaque) !void {
    try checkCode(c.curl_easy_setopt(self.handle, c.CURLOPT_DEBUGDATA, data));
}

pub fn setDebugfunction(
    self: Self,
    func: *const fn (*c.CURL, c.curl_infotype, [*]c_char, c_uint, *anyopaque) callconv(.c) c_int,
) !void {
    try checkCode(c.curl_easy_setopt(self.handle, c.CURLOPT_DEBUGFUNCTION, func));
}

pub fn setUsername(self: Self, username: [:0]const u8) !void {
    try checkCode(c.curl_easy_setopt(self.handle, c.CURLOPT_USERNAME, username.ptr));
}

pub fn setPassword(self: Self, password: [:0]const u8) !void {
    try checkCode(c.curl_easy_setopt(self.handle, c.CURLOPT_PASSWORD, password.ptr));
}

pub const IpResolve = enum(c_int) {
    whatever = c.CURL_IPRESOLVE_WHATEVER,
    v4 = c.CURL_IPRESOLVE_V4,
    v6 = c.CURL_IPRESOLVE_V6,
};

pub fn setIpResolve(self: Self, ipr: IpResolve) !void {
    try checkCode(c.curl_easy_setopt(self.handle, c.CURLOPT_IPRESOLVE, @intFromEnum(ipr)));
}

pub fn setInsecure(self: Self, enable: bool) !void {
    const param: c_long = @intCast(@intFromBool(!enable));
    try checkCode(c.curl_easy_setopt(self.handle, c.CURLOPT_SSL_VERIFYPEER, param));
    try checkCode(c.curl_easy_setopt(self.handle, c.CURLOPT_SSL_VERIFYHOST, param));
}

/// Perform sends an HTTP request and returns an HTTP response.
pub fn perform(self: Self) !Response {
    try self.setCommonOpts();
    try checkCode(c.curl_easy_perform(self.handle));

    var status_code: c_long = 0;
    try checkCode(c.curl_easy_getinfo(self.handle, c.CURLINFO_RESPONSE_CODE, &status_code));

    return .{
        .status_code = @intCast(status_code),
        .handle = self.handle,
    };
}

/// Head issues a HEAD to the specified URL.
pub fn head(self: Self, url: [:0]const u8) !Response {
    try self.setUrl(url);
    try self.setMethod(.HEAD);

    return self.perform();
}

/// Fetch issues a request to the specified URL.
pub fn fetch(
    self: Self,
    url: [:0]const u8,
    options: FetchOptions,
) !Response {
    try self.setUrl(url);
    try self.setMethod(options.method);
    if (options.body) |body| {
        try self.setPostFields(body);
    }
    var headers: ?Headers = null;
    if (options.headers) |header_slice| {
        headers = .{};
        for (header_slice) |header| {
            try headers.?.add(header);
        }
        try self.setHeaders(headers.?);
    }

    defer if (headers) |h| {
        h.deinit();
    };

    if (options.writer) |writer| {
        try self.setWriter(writer);
        const resp = try self.perform();
        try writer.flush();
        return resp;
    }

    return try self.perform();
}

/// Upload issues a PUT request to upload file.
/// `writeContext` is the same as in `fetch`, used to write the response body.
pub fn upload(self: Self, url: [:0]const u8, reader: *Reader, writer: *Writer) !Response {
    var up = try Upload.init(reader);
    try self.setUpload(&up);

    try self.setUrl(url);
    try self.setWriter(writer);
    const resp = try self.perform();
    try writer.flush();
    return resp;
}

/// A write callback that does nothing, used when you don't care about the response body.
pub fn discardWriteCallback(ptr: [*c]c_char, size: c_uint, nmemb: c_uint, user_data: *anyopaque) callconv(.c) c_uint {
    _ = ptr;
    _ = user_data;
    return size * nmemb;
}

/// A write callback that writes the response body to stdout.
pub fn stdoutWriteCallback(ptr: [*c]c_char, size: c_uint, nmemb: c_uint, user_data: *anyopaque) callconv(.c) c_uint {
    _ = user_data;
    const stdout = std.fs.File.stdout();
    var writer = stdout.writer(&.{}); // empty buffer means unbuffered
    const real_size = size * nmemb;
    const data = (@as([*]const u8, @ptrCast(ptr)))[0..real_size];
    writer.writeAll(data) catch {
        return 0;
    };
    return real_size;
}

pub fn setCommonOpts(self: Self) !void {
    if (self.ca_bundle) |bundle| {
        // https://curl.se/libcurl/c/CURLOPT_CAINFO_BLOB.html
        // Different TLS backends might require higher verison of libcurl.
        // BearSSL (since 7.79.0), mbedTLS (since 7.81.0), rustls (since 7.82.0), wolfSSL (since 8.2.0)
        if (!c.CURL_AT_LEAST_VERSION(7, 77, 0)) {
            return error.NoCaInfoBlobSupport;
        }
        const blob = c.curl_blob{
            .data = @constCast(bundle.items.ptr),
            .len = bundle.items.len,
            .flags = c.CURL_BLOB_NOCOPY,
        };
        try checkCode(c.curl_easy_setopt(self.handle, c.CURLOPT_CAINFO_BLOB, &blob));
    }
    try checkCode(c.curl_easy_setopt(self.handle, c.CURLOPT_TIMEOUT_MS, self.timeout_ms));
    try checkCode(c.curl_easy_setopt(self.handle, c.CURLOPT_USERAGENT, self.user_agent.ptr));
}
