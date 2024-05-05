const std = @import("std");
const errors = @import("errors.zig");
const util = @import("util.zig");
const c = util.c;

const mem = std.mem;
const fmt = std.fmt;
const Allocator = mem.Allocator;
const checkCode = errors.checkCode;
const Buffer = util.Buffer;

const has_parse_header_support = @import("util.zig").has_parse_header_support;

const Self = @This();

allocator: Allocator,
handle: *c.CURL,
timeout_ms: usize,
user_agent: [:0]const u8,
ca_bundle: ?Buffer,

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
    headers: ?*c.struct_curl_slist,
    allocator: Allocator,

    pub fn init(allocator: Allocator) !Headers {
        return .{
            .allocator = allocator,
            .headers = null,
        };
    }

    pub fn deinit(self: Headers) void {
        c.curl_slist_free_all(self.headers);
    }

    pub fn add(self: *Headers, name: []const u8, value: []const u8) !void {
        const header = try std.fmt.allocPrintZ(self.allocator, "{s}: {s}", .{ name, value });
        defer self.allocator.free(header);

        self.headers = c.curl_slist_append(self.headers, header);
    }
};

pub const Response = struct {
    body: ?Buffer = null,
    status_code: i32,

    handle: *c.CURL,
    allocator: Allocator,

    pub fn deinit(self: Response) void {
        if (self.body) |body| {
            body.deinit();
        }
    }

    pub const Header = struct {
        c_header: *c.struct_curl_header,
        name: []const u8,

        /// Get the first value associated with the given key.
        /// Applications need to copy the data if it wants to keep it around.
        pub fn get(self: Header) []const u8 {
            return mem.sliceTo(self.c_header.value, 0);
        }
    };

    /// Gets the header associated with the given name.
    pub fn getHeader(self: Response, name: [:0]const u8) errors.HeaderError!?Header {
        if (comptime !has_parse_header_support()) {
            return error.NoCurlHeaderSupport;
        }

        var header: ?*c.struct_curl_header = null;
        const code = c.curl_easy_header(self.handle, name.ptr, 0, c.CURLH_HEADER, -1, &header);
        return if (errors.headerErrorFrom(code)) |err|
            switch (err) {
                error.Missing => null,
                else => err,
            }
        else
            .{
                .c_header = header.?,
                .name = name,
            };
    }
};

pub const MultiPart = struct {
    mime_handle: *c.curl_mime,
    allocator: Allocator,

    pub const DataSource = union(enum) {
        /// Set a mime part's body content from memory data.
        /// Data will get copied when send request.
        /// Setting large data is memory consuming: one might consider using `data_callback` in such a case.
        data: []const u8,
        /// Set a mime part's body data from a file contents.
        file: [:0]const u8,
        // TODO: https://curl.se/libcurl/c/curl_mime_data_cb.html
        // data_callback: u8,
    };

    pub fn deinit(self: MultiPart) void {
        c.curl_mime_free(self.mime_handle);
    }

    pub fn addPart(self: MultiPart, name: [:0]const u8, source: DataSource) !void {
        const part = if (c.curl_mime_addpart(self.mime_handle)) |part| part else return error.MimeAddPart;

        try checkCode(c.curl_mime_name(part, name));
        switch (source) {
            .data => |slice| {
                try checkCode(c.curl_mime_data(part, slice.ptr, slice.len));
            },
            .file => |filepath| {
                try checkCode(c.curl_mime_filedata(part, filepath));
            },
        }
    }
};

/// Init options for Easy handle
pub const Options = struct {
    // Note that the vendored libcurl is compiled with mbedtls and does not include a CA bundle,
    // so this should be set when link with vendored libcurl, otherwise https
    // requests will fail.
    ca_bundle: ?Buffer = null,
    /// The maximum time in milliseconds that the entire transfer operation to take.
    default_timeout_ms: usize = 30_000,
    default_user_agent: [:0]const u8 = "zig-curl/0.1.0",
};

pub fn init(allocator: Allocator, options: Options) !Self {
    return if (c.curl_easy_init()) |handle|
        .{
            .allocator = allocator,
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

pub fn createHeaders(self: Self) !Headers {
    return Headers.init(self.allocator);
}

pub fn createMultiPart(self: Self) !MultiPart {
    return if (c.curl_mime_init(self.handle)) |h|
        .{
            .allocator = self.allocator,
            .mime_handle = h,
        }
    else
        error.MimeInit;
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

pub fn reset(self: Self) void {
    c.curl_easy_reset(self.handle);
}

pub fn setHeaders(self: Self, headers: Headers) !void {
    if (headers.headers) |c_headers| {
        try checkCode(c.curl_easy_setopt(self.handle, c.CURLOPT_HTTPHEADER, c_headers));
    }
}

pub fn setWritedata(self: Self, data: *const anyopaque) !void {
    try checkCode(c.curl_easy_setopt(self.handle, c.CURLOPT_WRITEDATA, data));
}

pub fn setWritefunction(
    self: Self,
    func: *const fn ([*c]c_char, c_uint, c_uint, *anyopaque) callconv(.C) c_uint,
) !void {
    try checkCode(c.curl_easy_setopt(self.handle, c.CURLOPT_WRITEFUNCTION, func));
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
        .body = null,
        .allocator = self.allocator,
    };
}

/// Get issues a GET to the specified URL.
pub fn get(self: Self, url: [:0]const u8) !Response {
    var buf = Buffer.init(self.allocator);
    try self.setWritefunction(bufferWriteCallback);
    try self.setWritedata(&buf);
    try self.setUrl(url);
    var resp = try self.perform();
    resp.body = buf;
    return resp;
}

/// Head issues a HEAD to the specified URL.
pub fn head(self: Self, url: [:0]const u8) !Response {
    try self.setUrl(url);
    try self.setMethod(.HEAD);

    return self.perform();
}

// /// Post issues a POST to the specified URL.
pub fn post(self: Self, url: [:0]const u8, content_type: []const u8, body: []const u8) !Response {
    var buf = Buffer.init(self.allocator);
    try self.setWritefunction(bufferWriteCallback);
    try self.setWritedata(&buf);
    try self.setUrl(url);
    try self.setPostFields(body);

    var headers = try self.createHeaders();
    defer headers.deinit();
    try headers.add("Content-Type", content_type);
    try self.setHeaders(headers);

    var resp = try self.perform();
    resp.body = buf;
    return resp;
}

/// Used for write response via `Buffer` type.
// https://curl.se/libcurl/c/CURLOPT_WRITEFUNCTION.html
// size_t write_callback(char *ptr, size_t size, size_t nmemb, void *userdata);
pub fn bufferWriteCallback(ptr: [*c]c_char, size: c_uint, nmemb: c_uint, user_data: *anyopaque) callconv(.C) c_uint {
    const real_size = size * nmemb;
    var buffer: *Buffer = @alignCast(@ptrCast(user_data));
    var typed_data: [*]u8 = @ptrCast(ptr);
    buffer.appendSlice(typed_data[0..real_size]) catch return 0;
    return real_size;
}

pub fn setCommonOpts(self: Self) !void {
    if (self.ca_bundle) |bundle| {
        const blob = c.curl_blob{
            .data = @constCast(bundle.items.ptr),
            .len = bundle.items.len,
            .flags = c.CURL_BLOB_NOCOPY,
        };
        try checkCode(c.curl_easy_setopt(self.handle, c.CURLOPT_CAINFO_BLOB, blob));
    }
    try checkCode(c.curl_easy_setopt(self.handle, c.CURLOPT_TIMEOUT_MS, self.timeout_ms));
    try checkCode(c.curl_easy_setopt(self.handle, c.CURLOPT_USERAGENT, self.user_agent.ptr));
}
