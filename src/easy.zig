const c = @import("c.zig").c;
const errors = @import("errors.zig");
const std = @import("std");
const mem = std.mem;
const fmt = std.fmt;

const has_curl_header = @import("c.zig").has_parse_header_support;
const polyfill_struct_curl_header = @import("c.zig").polyfill_struct_curl_header;

const Allocator = mem.Allocator;
const Self = @This();

allocator: Allocator,
handle: *c.CURL,
/// The maximum time in milliseconds that the entire transfer operation to take.
timeout_ms: usize = 30_000,
default_user_agent: []const u8 = "zig-curl/0.1.0",

pub const HEADER_CONTENT_TYPE: []const u8 = "Content-Type";
pub const HEADER_USER_AGENT: []const u8 = "User-Agent";

pub const Method = enum {
    GET,
    POST,
    PUT,
    HEAD,
    PATCH,
    DELETE,

    fn asString(self: @This()) [:0]const u8 {
        return @tagName(self);
    }
};

pub const RequestHeader = struct {
    entries: std.StringHashMap([]const u8),
    allocator: Allocator,

    pub fn init(allocator: Allocator) @This() {
        return .{
            .entries = std.StringHashMap([]const u8).init(allocator),
            .allocator = allocator,
        };
    }

    pub fn deinit(self: *@This()) void {
        self.entries.deinit();
    }

    pub fn add(self: *@This(), k: []const u8, v: []const u8) !void {
        try self.entries.put(k, v);
    }

    // Note: Caller should free returned list (after usage) with `freeCHeader`.
    fn asCHeader(self: @This(), ua: []const u8) !?*c.struct_curl_slist {
        if (self.entries.count() == 0) {
            return null;
        }

        var lst: ?*c.struct_curl_slist = null;
        var it = self.entries.iterator();
        var has_ua = false;
        while (it.next()) |entry| {
            if (!has_ua and std.ascii.eqlIgnoreCase(entry.key_ptr.*, HEADER_USER_AGENT)) {
                has_ua = true;
            }

            const kv = try fmt.allocPrintZ(self.allocator, "{s}: {s}", .{ entry.key_ptr.*, entry.value_ptr.* });
            defer self.allocator.free(kv);

            lst = c.curl_slist_append(lst, kv);
        }
        if (!has_ua) {
            const kv = try fmt.allocPrintZ(self.allocator, "{s}: {s}", .{ HEADER_USER_AGENT, ua });
            defer self.allocator.free(kv);

            lst = c.curl_slist_append(lst, kv);
        }

        return lst;
    }

    fn freeCHeader(lst: *c.struct_curl_slist) void {
        c.curl_slist_free_all(lst);
    }
};

pub const RequestArgs = struct {
    method: Method = .GET,
    header: ?RequestHeader = null,
    verbose: bool = false,
    /// Redirection limit, 0 refuse any redirect, -1 for an infinite number of redirects.
    redirects: i32 = 10,
    /// Max body size, default 128M.
    max_body_size: usize = 128 * 1024 * 1024,
};

pub fn Request(comptime ReaderType: type) type {
    return struct {
        url: []const u8,
        /// body is io.Reader or void
        body: ReaderType,
        args: RequestArgs,

        pub fn init(url: []const u8, body: ReaderType, args: RequestArgs) @This() {
            return .{
                .url = url,
                .body = body,
                .args = args,
            };
        }

        pub fn deinit(self: *@This()) void {
            if (self.args.header) |*h| {
                h.deinit();
            }
        }

        fn getVerbose(self: @This()) c_long {
            return if (self.args.verbose) 1 else 0;
        }

        fn getBody(self: @This(), allocator: Allocator) !?[]u8 {
            if (@TypeOf(self.body) == void) {
                return null;
            }

            return try self.body.readAllAlloc(allocator, self.args.max_body_size);
        }
    };
}

pub const Buffer = std.ArrayList(u8);
pub const Response = struct {
    body: Buffer,
    status_code: i32,

    handle: *c.CURL,
    allocator: Allocator,

    pub fn deinit(self: @This()) void {
        self.body.deinit();
    }

    pub const Header = struct {
        c_header: polyfill_struct_curl_header(),
        name: []const u8,

        /// Get the first value associated with the given key.
        /// Applications need to copy the data if it wants to keep it around.
        pub fn get(self: @This()) []const u8 {
            return mem.sliceTo(self.c_header.value, 0);
        }
    };

    /// Gets the header associated with the given name.
    pub fn get_header(self: @This(), name: []const u8) errors.HeaderError!?Header {
        if (comptime !has_curl_header()) {
            return error.NoCurlHeaderSupport;
        }

        const c_name = try fmt.allocPrintZ(self.allocator, "{s}", .{name});
        defer self.allocator.free(c_name);

        var header: ?*c.struct_curl_header = null;
        const code = c.curl_easy_header(self.handle, name.ptr, 0, c.CURLH_HEADER, -1, &header);
        return if (errors.headerErrorFrom(code)) |err|
            switch (err) {
                error.Missing => null,
                else => err,
            }
        else
            Header{
                .c_header = header.?,
                .name = name,
            };
    }
};

pub fn init(allocator: Allocator) !Self {
    const handle = c.curl_easy_init();
    if (handle == null) {
        return error.Init;
    }

    return .{
        .allocator = allocator,
        .handle = handle.?,
    };
}

pub fn deinit(self: Self) void {
    c.curl_easy_cleanup(self.handle);
}

/// Do sends an HTTP request and returns an HTTP response.
pub fn do(self: Self, req: anytype) !Response {
    try self.set_common_opts();

    const url = try fmt.allocPrintZ(self.allocator, "{s}", .{req.url});
    defer self.allocator.free(url);
    try checkCode(c.curl_easy_setopt(self.handle, c.CURLOPT_URL, url.ptr));

    try checkCode(c.curl_easy_setopt(self.handle, c.CURLOPT_MAXREDIRS, @as(c_long, req.args.redirects)));
    try checkCode(c.curl_easy_setopt(self.handle, c.CURLOPT_CUSTOMREQUEST, req.args.method.asString().ptr));
    try checkCode(c.curl_easy_setopt(self.handle, c.CURLOPT_VERBOSE, req.getVerbose()));

    const body = try req.getBody(self.allocator);
    defer if (body) |b| self.allocator.free(b);

    if (body) |b| {
        try checkCode(c.curl_easy_setopt(self.handle, c.CURLOPT_POSTFIELDS, b.ptr));
        try checkCode(c.curl_easy_setopt(self.handle, c.CURLOPT_POSTFIELDSIZE, b.len));
    } else {
        try checkCode(c.curl_easy_setopt(self.handle, c.CURLOPT_POSTFIELDSIZE, @as(c_long, 0)));
    }

    var header: ?*c.struct_curl_slist = null;
    if (req.args.header) |h| {
        header = try h.asCHeader(self.default_user_agent);
    }
    defer if (header) |h| RequestHeader.freeCHeader(h);

    try checkCode(c.curl_easy_setopt(self.handle, c.CURLOPT_HTTPHEADER, header));
    try checkCode(c.curl_easy_setopt(self.handle, c.CURLOPT_WRITEFUNCTION, write_callback));

    var resp_buffer = Buffer.init(self.allocator);
    errdefer resp_buffer.deinit();
    try checkCode(c.curl_easy_setopt(self.handle, c.CURLOPT_WRITEDATA, &resp_buffer));

    try checkCode(c.curl_easy_perform(self.handle));

    var status_code: i32 = 0;
    try checkCode(c.curl_easy_getinfo(self.handle, c.CURLINFO_RESPONSE_CODE, &status_code));

    return .{
        .status_code = status_code,
        .body = resp_buffer,
        .handle = self.handle,
        .allocator = self.allocator,
    };
}

/// Get issues a GET to the specified URL.
pub fn get(self: Self, url: []const u8) !Response {
    var req = Request(void).init(url, {}, .{});
    defer req.deinit();

    return self.do(req);
}

/// Head issues a HEAD to the specified URL.
pub fn head(self: Self, url: []const u8) !Response {
    var req = Request(void).init(url, {}, .{ .method = .HEAD });
    defer req.deinit();

    return self.do(req);
}

/// Post issues a POST to the specified URL.
pub fn post(self: Self, url: []const u8, content_type: []const u8, body: anytype) !Response {
    const header = blk: {
        var h = RequestHeader.init(self.allocator);
        errdefer h.deinit();
        try h.add(HEADER_CONTENT_TYPE, content_type);
        break :blk h;
    };
    var req = Request(@TypeOf(body)).init(url, body, .{
        .method = .POST,
        .header = header,
    });
    defer req.deinit();

    return self.do(req);
}

/// Used for https://curl.se/libcurl/c/CURLOPT_WRITEFUNCTION.html
// size_t write_callback(char *ptr, size_t size, size_t nmemb, void *userdata);
fn write_callback(ptr: [*c]c_char, size: c_uint, nmemb: c_uint, user_data: *anyopaque) callconv(.C) c_uint {
    const real_size = size * nmemb;

    var buffer: *Buffer = @alignCast(@ptrCast(user_data));
    var typed_data: [*]u8 = @ptrCast(ptr);
    buffer.appendSlice(typed_data[0..real_size]) catch return 0;

    return real_size;
}

fn checkCode(code: c.CURLcode) !void {
    if (code == c.CURLE_OK) {
        return;
    }

    // https://curl.se/libcurl/c/libcurl-errors.html
    std.log.debug("curl err code:{d}, msg:{s}\n", .{ code, c.curl_easy_strerror(code) });

    return error.Unepxected;
}

fn set_common_opts(self: Self) !void {
    try checkCode(c.curl_easy_setopt(self.handle, c.CURLOPT_TIMEOUT_MS, self.timeout_ms));
}
