const std = @import("std");
const Allocator = std.mem.Allocator;

const Encoder = std.base64.standard.Encoder;

pub fn encode_base64(allocator: Allocator, input: []const u8) ![]const u8 {
    const encoded_len = Encoder.calcSize(input.len);
    const dest = try allocator.alloc(u8, encoded_len);

    return Encoder.encode(dest, input);
}
