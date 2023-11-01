const std = @import("std");
const fs = std.fs;
const mem = std.mem;
const debug = std.debug;
const testing = std.testing;

/// Calculate the object name of a file
pub fn hashFile(file: fs.File) ![20]u8 {
    var hash_buffer: [20]u8 = undefined;
    var hash = std.crypto.hash.Sha1.init(.{});
    const hash_writer = hash.writer();
    const seekable = file.seekableStream();
    const file_reader = file.reader();
    try hash_writer.print("{s} {d}\x00", .{ @tagName(ObjectType.blob), try seekable.getEndPos() });
    const Pump = std.fifo.LinearFifo(u8, .{ .Static = 4096 });
    var pump = Pump.init();
    try seekable.seekTo(0);
    try pump.pump(file_reader, hash_writer);
    hash.final(&hash_buffer);
    return hash_buffer;
}

/// Hashes data and returns its object name
pub fn hashObject(data: []const u8, obj_type: ObjectType, digest: *[20]u8) void {
    var hash = std.crypto.hash.Sha1.init(.{});
    const writer = hash.writer();
    try writer.print("{s} {d}\x00", .{ @tagName(obj_type), data.len });
    try writer.writeAll(data);
    hash.final(digest);
}

/// Restores the contents of a file from an object
pub fn restoreFileFromObject(allocator: mem.Allocator, git_dir_path: []const u8, path: []const u8, object_name: [20]u8) !ObjectHeader {
    const file = try fs.cwd().createFile(path, .{});
    defer file.close();

    const writer = file.writer();
    return try loadObject(allocator, git_dir_path, object_name, writer);
}

// TODO Maybe rewrite to use a reader interface instead of a data slice
/// Writes data to an object and returns its object name
pub fn saveObject(allocator: mem.Allocator, git_dir_path: []const u8, data: []const u8, obj_type: ObjectType) ![20]u8 {
    var digest: [20]u8 = undefined;
    hashObject(data, obj_type, &digest);

    const hex_digest = try std.fmt.allocPrint(allocator, "{s}", .{ std.fmt.fmtSliceHexLower(&digest) });
    defer allocator.free(hex_digest);

    const path = try fs.path.join(allocator, &.{ git_dir_path, "objects", hex_digest[0..2], hex_digest[2..] });
    defer allocator.free(path);
    try fs.cwd().makePath(fs.path.dirname(path).?);

    const file = try fs.cwd().createFile(path, .{});
    defer file.close();

    // try zlibStreamWriter(allocator, file.writer(), .{});
    var compressor = try std.compress.zlib.compressStream(allocator, file.writer(), .{});
    defer compressor.deinit();

    const writer = compressor.writer();
    try writer.print("{s} {d}\x00", .{ @tagName(obj_type), data.len });
    try writer.writeAll(data);
    try compressor.finish();

    return digest;
}

/// Returns a reader for an object's data
pub fn objectReader(allocator: mem.Allocator, git_dir_path: []const u8, object_name: [20]u8) !ObjectReader {
    return ObjectReader.init(allocator, git_dir_path, object_name);
}

pub const ObjectReader = struct {
    decompressor: Decompressor,
    file: fs.File,
    header: ObjectHeader,

    pub const Decompressor = std.compress.zlib.DecompressStream(fs.File.Reader);
    pub const Reader = Decompressor.Reader;
    const Self = @This();

    pub fn reader(self: *Self) Reader {
        return self.decompressor.reader();
    }

    pub fn init(allocator: mem.Allocator, git_dir_path: []const u8, object_name: [20]u8) !ObjectReader {
        var hex_buffer: [40]u8 = undefined;
        const hex_digest = try std.fmt.bufPrint(&hex_buffer, "{s}", .{ std.fmt.fmtSliceHexLower(&object_name) });

        const path = try fs.path.join(allocator, &.{ git_dir_path, "objects", hex_digest[0..2], hex_digest[2..] });
        defer allocator.free(path);

        const file = try fs.cwd().openFile(path, .{});

        var decompressor = try std.compress.zlib.decompressStream(allocator, file.reader());
        const decompressor_reader = decompressor.reader();

        const header = try decompressor_reader.readUntilDelimiterAlloc(allocator, 0, 1024);
        defer allocator.free(header);

        var header_iter = mem.split(u8, header, " ");
        const object_type = std.meta.stringToEnum(ObjectType, header_iter.first()) orelse return error.InvalidObjectType;
        const size = blk: {
            const s = header_iter.next() orelse return error.InvalidObjectSize;
            const n = try std.fmt.parseInt(u32, s, 10);
            break :blk n;
        };

        const object_header = ObjectHeader{
            .type = object_type,
            .size = size,
        };

        return .{
            .decompressor = decompressor,
            .file = file,
            .header = object_header,
        };
    }

    pub fn deinit(self: *Self) void {
        self.decompressor.deinit();
        self.file.close();
    }
};

/// Returns the data for an object
pub fn loadObject(allocator: mem.Allocator, git_dir_path: []const u8, object_name: [20]u8, writer: anytype) !ObjectHeader {
    var object_reader = try objectReader(allocator, git_dir_path, object_name);
    defer object_reader.deinit();

    const reader = object_reader.reader();

    var fifo = std.fifo.LinearFifo(u8, .{ .Static = 4096 }).init();
    try fifo.pump(reader, writer);

    return object_reader.header;
}

pub const ObjectHeader = struct {
    type: ObjectType,
    size: u32,
};

pub const ObjectType = enum {
    blob,
    commit,
    tree,
    tag,
};
