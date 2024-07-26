const std = @import("std");
pub const c = @cImport({
    @cInclude("curl/curl.h");
});
const Allocator = std.mem.Allocator;
const Encoder = std.base64.standard.Encoder;
pub const Buffer = std.ArrayList(u8);

pub fn encode_base64(allocator: Allocator, input: []const u8) ![]const u8 {
    const encoded_len = Encoder.calcSize(input.len);
    const dest = try allocator.alloc(u8, encoded_len);

    return Encoder.encode(dest, input);
}

pub fn printLibcurlVersion() void {
    const v = c.curl_version_info(c.CURLVERSION_NOW);
    std.debug.print(
        \\Libcurl build info
        \\Host: {s}
        \\Version: {s}
        \\SSL version: {s}
        \\Libz version: {s}
        \\Protocols:
    , .{
        v.*.host,
        v.*.version,
        v.*.ssl_version,
        v.*.libz_version,
    });
    var i: usize = 0;
    while (v.*.protocols[i] != null) {
        std.debug.print(" {s}", .{
            v.*.protocols[i],
        });
        i += 1;
    } else {
        std.debug.print("\n", .{});
    }

    // feature_names is introduced in 7.87.0
    if (@hasField(c.struct_curl_version_info_data, "feature_names")) {
        std.debug.print("Features:", .{});
        i = 0;
        while (v.*.feature_names[i] != null) {
            std.debug.print(" {s}", .{
                v.*.feature_names[i],
            });
            i += 1;
        } else {
            std.debug.print("\n", .{});
        }
    }
}

pub fn hasParseHeaderSupport() bool {
    // `curl_header` is officially supported since 7.84.0.
    // https://everything.curl.dev/helpers/headerapi/index.html
    return c.CURL_AT_LEAST_VERSION(7, 84, 0);
}

comptime {
    // `CURL_AT_LEAST_VERSION` is only available since 7.43.0
    // https://curl.se/libcurl/c/symbols-in-versions.html
    if (!@hasDecl(c, "CURL_AT_LEAST_VERSION")) {
        @compileError("Libcurl version must at least 7.43.0");
    }
}

pub fn urlEncode(string: [:0]const u8) ?[]const u8 {
    const r = c.curl_easy_escape(null, string.ptr, @intCast(string.len));
    return std.mem.sliceTo(r.?, 0);
}

test "url encode" {
    inline for (.{
        .{
            "https://github.com/",
            "https%3A%2F%2Fgithub.com%2F",
        },
        .{
            "https://httpbin.org/anything/你好",
            "https%3A%2F%2Fhttpbin.org%2Fanything%2F%E4%BD%A0%E5%A5%BD",
        },
    }) |case| {
        const input = case.@"0";
        const expected = case.@"1";
        const actual = urlEncode(input);
        try std.testing.expectEqualStrings(expected, actual.?);
    }
}

const CERT_MARKER_BEGIN = "-----BEGIN CERTIFICATE-----";
const CERT_MARKER_END = "\n-----END CERTIFICATE-----\n";

pub fn allocCABundle(allocator: std.mem.Allocator) !Buffer {
    var bundle: std.crypto.Certificate.Bundle = .{};
    defer bundle.deinit(allocator);

    var blob = Buffer.init(allocator);
    try bundle.rescan(allocator);
    var iter = bundle.map.iterator();
    while (iter.next()) |entry| {
        const der = try std.crypto.Certificate.der.Element.parse(bundle.bytes.items, entry.value_ptr.*);
        const cert = bundle.bytes.items[entry.value_ptr.*..der.slice.end];
        const encoded = try encode_base64(allocator, cert);
        defer allocator.free(encoded);

        try blob.ensureUnusedCapacity(CERT_MARKER_BEGIN.len + CERT_MARKER_END.len + encoded.len);
        try blob.appendSlice(CERT_MARKER_BEGIN);
        for (encoded, 0..) |char, n| {
            if (n % 64 == 0) try blob.append('\n');
            try blob.append(char);
        }
        try blob.appendSlice(CERT_MARKER_END);
    }

    return blob;
}
