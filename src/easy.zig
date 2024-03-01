const std = @import("std");
const errors = @import("errors.zig");
const util = @import("util.zig");
const c = util.c;

const mem = std.mem;
const fmt = std.fmt;
const Allocator = mem.Allocator;
const checkCode = errors.checkCode;

const has_parse_header_support = @import("util.zig").has_parse_header_support;

const Self = @This();

allocator: Allocator,
handle: *c.CURL,
timeout_ms: usize,
ca_bundle: ?[]const u8,

const CERT_MARKER_BEGIN = "-----BEGIN CERTIFICATE-----";
const CERT_MARKER_END = "\n-----END CERTIFICATE-----\n";

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

pub const Buffer = std.ArrayList(u8);
pub const Response = struct {
    body: ?Buffer,
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
    pub fn get_header(self: Response, name: [:0]const u8) errors.HeaderError!?Header {
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

    pub fn add_part(self: MultiPart, name: [:0]const u8, source: DataSource) !void {
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
pub const EasyOptions = struct {
    /// Use zig's std.crypto.Certificate.Bundle for TLS instead of libcurl's default.
    // Note that the builtin libcurl is compiled with mbedtls and does not include a CA bundle,
    // so this defaults to true when link_vendor is enabled.
    use_std_crypto_ca_bundle: bool = @import("build_info").link_vendor,
    /// The maximum time in milliseconds that the entire transfer operation to take.
    default_timeout_ms: usize = 30_000,
};

pub fn init(allocator: Allocator, options: EasyOptions) !Self {
    const ca_bundle = blk: {
        if (options.use_std_crypto_ca_bundle) {
            var bundle: std.crypto.Certificate.Bundle = .{};
            defer bundle.deinit(allocator);

            try bundle.rescan(allocator);
            var blob = std.ArrayList(u8).init(allocator);
            var iter = bundle.map.iterator();
            while (iter.next()) |entry| {
                const der = try std.crypto.Certificate.der.Element.parse(bundle.bytes.items, entry.value_ptr.*);
                const cert = bundle.bytes.items[entry.value_ptr.*..der.slice.end];
                const encoded = try util.encode_base64(allocator, cert);
                defer allocator.free(encoded);

                try blob.ensureUnusedCapacity(CERT_MARKER_BEGIN.len + CERT_MARKER_END.len + encoded.len);
                try blob.appendSlice(CERT_MARKER_BEGIN);
                for (encoded, 0..) |char, n| {
                    if (n % 64 == 0) try blob.append('\n');
                    try blob.append(char);
                }
                try blob.appendSlice(CERT_MARKER_END);
            }
            break :blk try blob.toOwnedSlice();
        } else {
            break :blk null;
        }
    };

    return if (c.curl_easy_init()) |handle|
        .{
            .allocator = allocator,
            .handle = handle,
            .timeout_ms = options.default_timeout_ms,
            .ca_bundle = ca_bundle,
        }
    else
        error.CurlInit;
}

pub fn deinit(self: Self) void {
    if (self.ca_bundle) |bundle| {
        self.allocator.free(bundle);
    }

    c.curl_easy_cleanup(self.handle);
}

pub fn create_headers(self: Self) !Headers {
    return Headers.init(self.allocator);
}

pub fn create_multi_part(self: Self) !MultiPart {
    return if (c.curl_mime_init(self.handle)) |h|
        .{
            .allocator = self.allocator,
            .mime_handle = h,
        }
    else
        error.MimeInit;
}

pub fn set_url(self: Self, url: [:0]const u8) !void {
    try checkCode(c.curl_easy_setopt(self.handle, c.CURLOPT_URL, url.ptr));
}

pub fn set_max_redirects(self: Self, redirects: u32) !void {
    try checkCode(c.curl_easy_setopt(self.handle, c.CURLOPT_MAXREDIRS, @as(c_long, redirects)));
}

pub fn set_method(self: Self, method: Method) !void {
    try checkCode(c.curl_easy_setopt(self.handle, c.CURLOPT_CUSTOMREQUEST, method.asString().ptr));
}

pub fn set_verbose(self: Self, verbose: bool) !void {
    try checkCode(c.curl_easy_setopt(self.handle, c.CURLOPT_VERBOSE, verbose));
}

pub fn set_post_fields(self: Self, body: []const u8) !void {
    try checkCode(c.curl_easy_setopt(self.handle, c.CURLOPT_POSTFIELDS, body.ptr));
    try checkCode(c.curl_easy_setopt(self.handle, c.CURLOPT_POSTFIELDSIZE, body.len));
}

pub fn set_multi_part(self: Self, multi_part: MultiPart) !void {
    try checkCode(c.curl_easy_setopt(self.handle, c.CURLOPT_MIMEPOST, multi_part.mime_handle));
}

pub fn reset(self: Self) void {
    c.curl_easy_reset(self.handle);
}

pub fn set_headers(self: Self, headers: Headers) !void {
    if (headers.headers) |c_headers| {
        try checkCode(c.curl_easy_setopt(self.handle, c.CURLOPT_HTTPHEADER, c_headers));
    }
}

pub fn set_writedata(self: Self, data: *const anyopaque) !void {
    try checkCode(c.curl_easy_setopt(self.handle, c.CURLOPT_WRITEDATA, data));
}

pub fn set_writefunction(
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
    try self.set_writefunction(bufferWriteCallback);
    try self.set_writedata(&buf);
    try self.set_url(url);
    var resp = try self.perform();
    resp.body = buf;
    return resp;
}

/// Head issues a HEAD to the specified URL.
pub fn head(self: Self, url: [:0]const u8) !Response {
    try self.set_url(url);
    try self.set_method(.HEAD);

    return self.perform();
}

// /// Post issues a POST to the specified URL.
pub fn post(self: Self, url: [:0]const u8, content_type: []const u8, body: []const u8) !Response {
    var buf = Buffer.init(self.allocator);
    try self.set_writefunction(bufferWriteCallback);
    try self.set_writedata(&buf);
    try self.set_url(url);
    try self.set_post_fields(body);

    var headers = try self.create_headers();
    defer headers.deinit();
    try headers.add("Content-Type", content_type);
    try self.set_headers(headers);

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
            .data = @constCast(bundle.ptr),
            .len = bundle.len,
            .flags = c.CURL_BLOB_NOCOPY,
        };
        try checkCode(c.curl_easy_setopt(self.handle, c.CURLOPT_CAINFO_BLOB, blob));
    }
    try checkCode(c.curl_easy_setopt(self.handle, c.CURLOPT_TIMEOUT_MS, self.timeout_ms));
}
