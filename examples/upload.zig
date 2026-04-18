const std = @import("std");
const println = @import("util.zig").println;
const curl = @import("curl");
const Allocator = std.mem.Allocator;

const URL = "https://edgebin.liujiacai.net/anything";

pub fn main(init: std.process.Init) !void {
    println("Upload demo");
    var gpa = std.heap.DebugAllocator(.{}){};
    defer if (gpa.deinit() != .ok) @panic("leak");
    const allocator = gpa.allocator();

    var ca_bundle = try curl.allocCABundle(allocator, init.io);
    defer ca_bundle.deinit(allocator);
    var easy = try curl.Easy.init(.{
        .ca_bundle = ca_bundle,
    });
    defer easy.deinit();

    const path = "examples/test.txt";
    var writer = std.Io.Writer.Allocating.init(allocator);
    defer writer.deinit();

    const file = try std.Io.Dir.cwd().openFile(init.io, path, .{});
    defer file.close(init.io);

    var buf: [4096]u8 = undefined;
    var reader = file.reader(init.io, &buf);
    const response = try easy.upload(URL, &reader.interface, &writer.writer);

    std.debug.print("Status code: {d}\nBody: {s}\n", .{
        response.status_code,
        writer.writer.buffered(),
    });

    easy.reset();

    // Upload with multipart/form-data
    try multipartUpload(allocator, &easy);
}

fn multipartUpload(allocator: Allocator, easy: *curl.Easy) !void {
    std.debug.print("Multipart upload demo\n", .{});
    try easy.setUrl(URL);
    var multi_part = try easy.createMultiPart();
    defer multi_part.deinit();

    var slice = curl.MultiPart.NonCopyingData.SliceBased.init("slice non-copying");
    try multi_part.addPart("non-copying-data", .{
        .non_copying = slice.nonCopying(),
    });
    var reader = std.Io.Reader.fixed("reader non-copying");
    var reader_data = curl.MultiPart.NonCopyingData.ReaderBased.init(reader.end, &reader);
    try multi_part.addPart("non-copying-data-2", .{
        .non_copying = reader_data.nonCopying(),
    });
    try multi_part.addPart("copying-data", .{
        .data = "copying data",
    });
    try multi_part.addPart("file-data", .{
        .file = "examples/test.txt",
    });
    var writer = std.Io.Writer.Allocating.init(allocator);
    defer writer.deinit();

    try easy.setWriter(&writer.writer);
    try easy.setMultiPart(multi_part);
    const multipart_response = try easy.perform();
    std.debug.print("Status code: {d}\n{s}", .{
        multipart_response.status_code,
        writer.writer.buffered(),
    });
}
