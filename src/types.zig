const std = @import("std");
pub const c = @cImport({
    @cInclude("curl/curl.h");
});

pub const ResizableBuffer = std.array_list.Managed(u8);
