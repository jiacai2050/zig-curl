pub const Easy = @import("easy.zig");
// pub const request = Easy.request;
// pub const Request = Easy.Request;
// pub const Response = Easy.Response;

pub usingnamespace Easy;
pub const print_libcurl_version = @import("c.zig").print_libcurl_version;
pub const has_curl_header_support = @import("c.zig").has_curl_header_support;
