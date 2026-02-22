//! MultiPart module provides support for multipart/form-data requests.
//!
//! It allows you to create and manage multipart form data, which is commonly used for file uploads and form submissions in HTTP requests.
//!
//! More see: https://curl.se/libcurl/c/curl_mime_init.html

const std = @import("std");
const util = @import("util.zig");
const Easy = @import("Easy.zig");
const c = util.c;
const checkCode = @import("errors.zig").checkCode;
const Reader = std.Io.Reader;

mime_handle: *c.curl_mime,

/// `NonCopyingData` allows setting a mime part's body data from a custom source without copying the data.
///
/// Modelled after [curl_mime_data_cb](https://curl.se/libcurl/c/curl_mime_data_cb.html).
/// There are two built-in implementations: `SliceBased` and `ReaderBased`.
/// One can also implement their own source by providing a `VTable`.
pub const NonCopyingData = struct {
    size: usize,
    ptr: *anyopaque,
    vtable: *const VTable,

    const VTable = struct {
        // ?*const fn ([*c]u8, usize, usize, ?*anyopaque) callconv(.c) usize;
        read: c.curl_read_callback,
        // ?*const fn (?*anyopaque, curl_off_t, c_int) callconv(.c) c_int;
        seek: c.curl_seek_callback,
        // ?*const fn (?*anyopaque) callconv(.c) void;
        free: c.curl_free_callback,
    };

    /// A `NonCopyingData` source based on a slice.
    /// The slice data will not be copied, so it must remain valid until the request is completed.
    /// It support `read` and `seek` operations.
    pub const SliceBased = struct {
        data_with_offset: DataWithOffset,

        const DataWithOffset = struct {
            slice: []const u8,
            offset: usize,
        };

        pub fn init(slice: []const u8) SliceBased {
            return .{
                .data_with_offset = .{
                    .slice = slice,
                    .offset = 0,
                },
            };
        }

        pub fn nonCopying(self: *SliceBased) NonCopyingData {
            return .{
                .size = self.data_with_offset.slice.len,
                .ptr = @ptrCast(&self.data_with_offset),
                .vtable = &.{
                    .read = read,
                    .seek = seek,
                    .free = null,
                },
            };
        }

        fn read(dest: [*c]u8, size: usize, nmemb: usize, user_data: ?*anyopaque) callconv(.c) usize {
            var source: *DataWithOffset = @ptrCast(@alignCast(user_data orelse return c.CURL_READFUNC_ABORT));
            var to_read = size * nmemb;
            const remaining = source.slice.len - source.offset;
            if (to_read > remaining) {
                to_read = remaining;
            }

            std.mem.copyForwards(u8, dest[0..to_read], source.slice[source.offset .. source.offset + to_read]);
            source.offset += to_read;
            return to_read;
        }

        pub fn seek(user_data: ?*anyopaque, offset: c.curl_off_t, origin: c_int) callconv(.c) c_int {
            var source: *DataWithOffset = @ptrCast(@alignCast(user_data orelse return c.CURL_SEEKFUNC_FAIL));
            const new_pos = switch (origin) {
                c.SEEK_SET => offset,
                c.SEEK_CUR => offset + @as(c.curl_off_t, @intCast(source.offset)),
                else => return c.CURL_SEEKFUNC_FAIL,
            };
            if (new_pos < 0) {
                return c.CURL_SEEKFUNC_FAIL;
            }
            const new_offset = @as(usize, @intCast(new_pos));
            if (new_offset > source.slice.len) {
                return c.CURL_SEEKFUNC_FAIL;
            }
            source.offset = new_offset;
            return c.CURL_SEEKFUNC_OK;
        }
    };

    /// A `NonCopyingData` source based on a `Reader`.
    /// The reader must remain valid until the request is completed.
    /// It only support `read` operation.
    pub const ReaderBased = struct {
        reader: *Reader,
        size: usize,

        pub fn init(size: usize, reader: *Reader) ReaderBased {
            return .{
                .reader = reader,
                .size = size,
            };
        }

        pub fn nonCopying(self: *ReaderBased) NonCopyingData {
            return .{
                .size = self.size,
                .ptr = @ptrCast(self.reader),
                .vtable = &.{
                    .read = read,
                    .seek = null,
                    .free = null,
                },
            };
        }

        fn read(dest: [*c]u8, size: usize, nmemb: usize, user_data: ?*anyopaque) callconv(.c) usize {
            var source: *Reader = @ptrCast(@alignCast(user_data orelse return c.CURL_READFUNC_ABORT));
            const to_read = size * nmemb;
            const n = source.readSliceShort(dest[0..to_read]) catch return c.CURL_READFUNC_ABORT;
            return n;
        }
    };
};

pub const DataSource = union(enum) {
    /// Set a mime part's body content from memory data.
    /// Data will get copied when send request.
    /// Setting large data is memory consuming: one might consider using `non_copying` in such a case.
    data: []const u8,
    /// Set a mime part's body data from a file contents.
    file: [:0]const u8,
    /// Data will NOT get copied when send request, so the data source must remain valid until
    /// the request is completed.
    non_copying: NonCopyingData,
};

pub fn init(easy: Easy) !@This() {
    const mime_handle = if (c.curl_mime_init(easy.handle)) |mh| mh else return error.MimeInit;
    return .{
        .mime_handle = mime_handle,
    };
}

pub fn deinit(self: @This()) void {
    c.curl_mime_free(self.mime_handle);
}

pub fn addPart(self: @This(), name: [:0]const u8, source: DataSource) !void {
    const part = if (c.curl_mime_addpart(self.mime_handle)) |part| part else return error.MimeAddPart;

    try checkCode(c.curl_mime_name(part, name));
    switch (source) {
        .data => |slice| {
            try checkCode(c.curl_mime_data(part, slice.ptr, slice.len));
        },
        .file => |filepath| {
            try checkCode(c.curl_mime_filedata(part, filepath));
        },
        .non_copying => |ncdata| {
            try checkCode(c.curl_mime_data_cb(
                part,
                @intCast(ncdata.size),
                ncdata.vtable.read,
                ncdata.vtable.seek,
                ncdata.vtable.free,
                ncdata.ptr,
            ));
        },
    }
}
