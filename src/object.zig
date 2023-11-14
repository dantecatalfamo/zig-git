const std = @import("std");
const fs = std.fs;
const mem = std.mem;
const debug = std.debug;
const testing = std.testing;

const pack_zig = @import("pack.zig");
const pack_index_zig = @import("pack_index.zig");
const pack_delta_zig = @import("pack_delta.zig");
const DeltaInstructions = pack_delta_zig.DeltaInstructions;

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
    var pack_object_reader_valid = true;
    defer {
        // This is a hack but it works
        if (pack_object_reader_valid)
            pack_object_reader.deinit();
    }

    const pack_reader = pack_object_reader.reader();
    const pack_object_type = pack_object_reader.object_reader.header.type;

    if (packObjectTypeToObjectType(pack_object_type)) |object_type| {
        try fifo.pump(pack_reader, writer);

        return ObjectHeader{
            .type = object_type,
            .size = pack_object_reader.object_reader.header.size,
        };
    }

    var delta_stack = DeltaStack.init(allocator);
    defer delta_stack.deinit();

    const first_instructions = try pack_delta_zig.parseDeltaInstructions(allocator, pack_object_reader.object_reader.header.size, pack_reader);
    try delta_stack.push(pack_object_reader.object_reader.header);
    delta_stack.last().instructions = first_instructions;

    // we gotta keep going down the stack until we reach a non-delta,
    // then unwind the stack and apply the deltas...
    while (delta_stack.last().header.delta) |ref_type| {
        var instructions = delta_stack.last().instructions.?;

        if (ref_type == .ref) {
            std.debug.print("Ref delta: {s}\n", .{ std.fmt.fmtSliceHexLower(&ref_type.ref) });
            pack_object_reader.deinit();
            pack_object_reader_valid = false;
            // I would be shocked if a pack ever referred to a loose object
            pack_object_reader = try pack_zig.packObjectReader(allocator, git_dir_path, ref_type.ref);
            pack_object_reader_valid = true;
        } else {
            const object_offset = pack_object_reader.object_reader.offset - ref_type.offset;
            std.debug.print("Ofs delta: {d}, current: {d}\n", .{object_offset, pack_object_reader.object_reader.offset});
            try pack_object_reader.setOffset(object_offset);
        }

        const base_object_header = pack_object_reader.object_reader.header;
        try delta_stack.push(base_object_header);

        if (packObjectTypeToObjectType(base_object_header.type) == null) {
            // another delta
            const base_object_buffer = try allocator.alloc(u8, instructions.base_size);
            defer allocator.free(base_object_buffer);

            var base_object_stream = std.io.fixedBufferStream(base_object_buffer);
            try fifo.pump(pack_object_reader.reader(), base_object_stream.writer());

            var new_instructions = try pack_delta_zig.parseDeltaInstructions(allocator, base_object_header.size, base_object_stream.reader());
            delta_stack.last().instructions = new_instructions;
        } else {
            // finally base object
            try fifo.pump(pack_object_reader.reader(), delta_stack.last().base_object.writer());
        }
    }

    // @panic("we made it");
    // var buffer_stream = delta_stack.last().bufferStream();
    // try fifo.pump(buffer_stream.reader(), writer);
    return error.What;
}

pub const DeltaStack = struct {
    stack: std.ArrayList(DeltaFrame),

    pub fn init(allocator: mem.Allocator) DeltaStack {
        return .{ .stack = std.ArrayList(DeltaFrame).init(allocator) };
    }

    pub fn last(self: DeltaStack) *DeltaFrame {
        return &self.stack.items[self.stack.items.len-1];
    }

    pub fn second_last(self: DeltaStack) *DeltaFrame {
        return &self.stack.items[self.stack.items.len-2];
    }

    pub fn count(self: DeltaStack) usize {
        return self.stack.items.len;
    }

    pub fn push(self: *DeltaStack, header: pack_zig.ObjectHeader) !void {
        try self.stack.append(.{
            .instructions = null,
            .base_object = std.ArrayList(u8).init(self.stack.allocator),
            .header = header,
        });
    }

    pub fn pop(self: *DeltaStack) void {
        var last_frame = self.last();
        if (last_frame.instructions) |instructions|
            instructions.deinit();
        last_frame.base_object.deinit();
        _ = self.stack.pop();
    }

    pub fn deinit(self: *DeltaStack) void {
        while (self.count() > 0) {
            self.pop();
        }
        self.stack.deinit();
    }
};

pub const DeltaFrame = struct {
    instructions: ?DeltaInstructions,
    base_object: std.ArrayList(u8),
    header: pack_zig.ObjectHeader,

    const BufferStream = std.io.FixedBufferStream([]const u8);

    pub fn bufferStream(self: DeltaFrame) BufferStream {
        return std.io.fixedBufferStream(self.expanded_object);
    }
};

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
