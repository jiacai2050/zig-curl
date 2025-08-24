const std = @import("std");
pub const c = @cImport({
    @cInclude("curl/curl.h");
});
const GenericWriter = std.io.GenericWriter;
const AnyWriter = std.io.AnyWriter;
const Allocator = std.mem.Allocator;

// Not used yet, but reserved for future use.
// pub const ResponseWriter = struct {
//     pub const VTable = struct {
//         /// A function that writes the response body to a context.
//         /// The function should return the number of bytes written, or 0 to indicate an error.
//         write: fn (context: *anyopaque, data: []const u8) usize,
//     };
//     ctx: *anyopaque,
// };

pub const ResizableBuffer = std.array_list.Managed(u8);

pub const FixedResponseWriter = struct {
    buffer: []u8,
    // How many bytes are used in the buffer.
    size: usize,

    const Self = @This();

    /// Initializes a new `FixedResponseWriter` with the given data buffer.
    /// The buffer must be large enough to hold the response data.
    pub fn init(data: []u8) Self {
        return .{ .buffer = data, .size = 0 };
    }

    fn write(
        w: *const anyopaque,
        data: []const u8,
    ) anyerror!usize {
        var writer: *Self = @ptrCast(@alignCast(@constCast(w)));
        if (writer.size + data.len > writer.buffer.len) {
            return error.BufferOverflow;
        }
        std.mem.copyForwards(u8, writer.buffer[writer.size..], data);
        writer.size += data.len;
        return data.len;
    }

    pub fn asAny(self: *Self) AnyWriter {
        return .{ .context = @ptrCast(self), .writeFn = Self.write };
    }

    pub fn asSlice(self: FixedResponseWriter) []const u8 {
        return self.buffer[0..self.size];
    }
};

pub const ResizableResponseWriter = struct {
    buffer: ResizableBuffer,

    const Self = @This();

    pub fn init(allocator: Allocator) Self {
        return .{ .buffer = ResizableBuffer.init(allocator) };
    }

    pub fn deinit(self: Self) void {
        self.buffer.deinit();
    }

    fn write(
        any: *const anyopaque,
        data: []const u8,
    ) anyerror!usize {
        var writer: *Self = @ptrCast(@alignCast(@constCast(any)));
        try writer.buffer.appendSlice(data);
        return data.len;
    }

    pub fn asAny(self: *Self) AnyWriter {
        return .{ .context = @ptrCast(self), .writeFn = Self.write };
    }

    pub fn asSlice(self: *const Self) []const u8 {
        return self.buffer.items;
    }
};
