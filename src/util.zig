const std = @import("std");
const c = @import("c.zig").c;
const Allocator = std.mem.Allocator;
const Encoder = std.base64.standard.Encoder;

pub const HEADER_CONTENT_TYPE: []const u8 = "Content-Type";
pub const HEADER_USER_AGENT: []const u8 = "User-Agent";

pub fn encode_base64(allocator: Allocator, input: []const u8) ![]const u8 {
    const encoded_len = Encoder.calcSize(input.len);
    const dest = try allocator.alloc(u8, encoded_len);

    return Encoder.encode(dest, input);
}

pub fn map_to_headers(allocator: std.mem.Allocator, map: std.StringHashMap([]const u8), user_agent: []const u8) !*c.struct_curl_slist {
    var headers: ?*c.struct_curl_slist = null;
    var has_ua = false;
    var iterator = map.iterator();
    while (iterator.next()) |item| {
        const key = item.key_ptr.*;
        const value = item.value_ptr.*;
        const header = try std.fmt.allocPrintZ(allocator, "{s}: {s}", .{ key, value });
        defer allocator.free(header);

        headers = c.curl_slist_append(headers, header);

        if (!has_ua and std.ascii.eqlIgnoreCase(key, HEADER_USER_AGENT)) {
            has_ua = true;
        }
    }
    if (!has_ua) {
        const kv = try std.fmt.allocPrintZ(allocator, "{s}: {s}", .{ HEADER_USER_AGENT, user_agent });
        defer allocator.free(kv);

        headers = c.curl_slist_append(headers, kv);
    }
    return headers.?;
}
