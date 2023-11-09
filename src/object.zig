const std = @import("std");
const fs = std.fs;
const mem = std.mem;
const debug = std.debug;
const testing = std.testing;

const pack_zig = @import("pack.zig");
const pack_index_zig = @import("pack_index.zig");
const pack_delta_zig = @import("pack_delta.zig");

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
pub fn looseObjectReader(allocator: mem.Allocator, git_dir_path: []const u8, object_name: [20]u8) !?LooseObjectReader {
    return LooseObjectReader.init(allocator, git_dir_path, object_name);
}

pub const LooseObjectReader = struct {
    decompressor: Decompressor,
    file: fs.File,
    header: ObjectHeader,

    pub const Decompressor = std.compress.zlib.DecompressStream(fs.File.Reader);
    pub const Reader = Decompressor.Reader;
    const Self = @This();

    pub fn reader(self: *Self) Reader {
        return self.decompressor.reader();
    }

    pub fn init(allocator: mem.Allocator, git_dir_path: []const u8, object_name: [20]u8) !?LooseObjectReader {
        var hex_buffer: [40]u8 = undefined;
        const hex_digest = try std.fmt.bufPrint(&hex_buffer, "{s}", .{ std.fmt.fmtSliceHexLower(&object_name) });

        const path = try fs.path.join(allocator, &.{ git_dir_path, "objects", hex_digest[0..2], hex_digest[2..] });
        defer allocator.free(path);

        const file = fs.cwd().openFile(path, .{}) catch |err| switch (err) {
            error.FileNotFound => return null,
            else => return err,
        };

        var decompressor = try std.compress.zlib.decompressStream(allocator, file.reader());
        const decompressor_reader = decompressor.reader();

        const header = try decompressor_reader.readUntilDelimiterAlloc(allocator, 0, 1024);
        defer allocator.free(header);

        var header_iter = mem.split(u8, header, " ");
        const object_type = std.meta.stringToEnum(ObjectType, header_iter.first()) orelse return error.InvalidObjectType;
        const size = blk: {
            const s = header_iter.next() orelse return error.InvalidObjectSize;
            const n = try std.fmt.parseInt(usize, s, 10);
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

/// Writes the data from an object to a writer
pub fn loadObject(allocator: mem.Allocator, git_dir_path: []const u8, object_name: [20]u8, writer: anytype) !ObjectHeader {
    var fifo = std.fifo.LinearFifo(u8, .{ .Static = 4096 }).init();

    var loose_object_reader = try looseObjectReader(allocator, git_dir_path, object_name);
    if (loose_object_reader) |*object_reader| {
        defer object_reader.deinit();

        const reader = object_reader.reader();

        try fifo.pump(reader, writer);

        return object_reader.header;
    }

    var pack_object_reader = try pack_zig.packObjectReader(allocator, git_dir_path, object_name);
    defer pack_object_reader.deinit();

    const pack_reader = pack_object_reader.reader();
    const pack_object_type = pack_object_reader.object_reader.header.type;

    if (packObjectTypeToObjectType(pack_object_type)) |object_type| {
        try fifo.pump(pack_reader, writer);

        return ObjectHeader{
            .type = object_type,
            .size = pack_object_reader.object_reader.header.size,
        };
    }

    const delta_instructions = try pack_delta_zig.parseDeltaInstructions(allocator, pack_object_reader.object_reader.header.size, pack_reader);
    defer delta_instructions.deinit();

    const base_object = try allocator.alloc(u8, delta_instructions.base_size);
    defer allocator.free(base_object);

    var base_object_stream = std.io.fixedBufferStream(base_object);

    var delta_object_header: ObjectHeader = undefined;

    if (pack_object_type == .ref_delta) {
        delta_object_header = try loadObject(allocator, git_dir_path, pack_object_reader.object_reader.header.delta.?.ref, base_object_stream.writer());
    } else {
        var pack_offset_reader = try pack_object_reader.pack.readObjectAt(pack_object_reader.object_reader.offset);
        defer pack_offset_reader.deinit();

        if (packObjectTypeToObjectType(pack_offset_reader.header.type)) |object_type| {
            delta_object_header = ObjectHeader{
                .type = object_type,
                .size = delta_instructions.expanded_size,
            };
        } else {
            // TODO make it work
            return error.RecursiveDelta;
        }

        try fifo.pump(pack_offset_reader.reader(), base_object_stream.writer());
    }

    for (delta_instructions.deltas) |delta| {
        switch (delta) {
            .copy => |copy| {
                try writer.writeAll(base_object[copy.offset..copy.offset+copy.size]);
            },
            .data => |data| {
                try writer.writeAll(data);
            }
        }
    }

    return delta_object_header;
}

pub fn packObjectTypeToObjectType(pack_object_type: pack_zig.PackObjectType) ?ObjectType {
    return switch (pack_object_type) {
        .commit => .commit,
        .tree => .tree,
        .blob => .blob,
        .tag => .tag,
        else => null,
    };
}

pub const ObjectHeader = struct {
    type: ObjectType,
    size: usize,
};

pub const ObjectType = enum {
    blob,
    commit,
    tree,
    tag,
};

// pub fn expandPackDelta(allocator: mem.Allocator, reader: anytype, writer: anytype) !void {

// }
