const std = @import("std");
pub const c = @cImport({
    @cInclude("curl/curl.h");
});

pub fn print_libcurl_version() void {
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

pub fn has_parse_header_support() bool {
    // `curl_header` is officially supported since 7.84.0.
    // https://curl.se/libcurl/c/curl_easy_header.html
    return c.CURL_AT_LEAST_VERSION(7, 84, 0);
}

comptime {
    // `curl_easy_reset` is only available since 7.12.0
    if (!c.CURL_AT_LEAST_VERSION(7, 12, 0)) {
        @compileError("Libcurl version must at least 7.12.0");
    }
}

pub fn url_encode(string: [:0]const u8) ?[]const u8 {
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
        const actual = url_encode(input);
        try std.testing.expectEqualStrings(expected, actual.?);
    }
}
