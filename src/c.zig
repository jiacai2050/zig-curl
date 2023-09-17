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

pub fn polyfill_struct_curl_header() type {
    if (has_curl_header_support()) {
        return *c.struct_curl_header;
    } else {
        // return a dummy struct to make it compile on old version.
        return struct {
            value: [:0]const u8,
        };
    }
}

pub fn has_curl_header_support() bool {
    // `curl_header` is officially supported since 7.84.0.
    // https://curl.se/libcurl/c/curl_easy_header.html
    return c.CURL_AT_LEAST_VERSION(7, 84, 0);
}
