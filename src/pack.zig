const std = @import("std");
const debug = std.debug;
const fs = std.fs;
const mem = std.mem;
const os = std.os;
const testing = std.testing;

const pack_index_zig = @import("pack_index.zig");
const helpers_zig = @import("helpers.zig");
const parseVariableLength = helpers_zig.parseVariableLength;


pub fn packObjectReader(allocator: mem.Allocator, git_dir_path: []const u8, object_name: [20]u8) !*PackObjectReader {
    const search_result = try pack_index_zig.searchPackIndicies(allocator, git_dir_path, object_name);
    return try readObjectFromPack(allocator, git_dir_path, search_result.pack, search_result.offset);
}

pub fn readObjectFromPack(allocator: mem.Allocator, git_dir_path: []const u8, pack_name: [20]u8, offset: u64) !*PackObjectReader {
    const pack_file_name = try std.fmt.allocPrint(allocator, "pack-{s}.pack", .{ std.fmt.fmtSliceHexLower(&pack_name) });
    defer allocator.free(pack_file_name);

    const pack_file_path = try fs.path.join(allocator, &.{ git_dir_path, "objects", "pack", pack_file_name });
    defer allocator.free(pack_file_path);

    var pack = try Pack.init(allocator, pack_file_path);
    errdefer pack.deinit();

    return PackObjectReader.init(allocator, pack, offset);
}

pub const PackObjectReader = struct {
    allocator: mem.Allocator,
    pack: *Pack,
    object_reader: ObjectReader,

    const Reader = ObjectReader.Reader;

    pub fn init(allocator: mem.Allocator, pack: *Pack, offset: usize) !*PackObjectReader {
        var pack_object_reader = try allocator.create(PackObjectReader);
        pack_object_reader.* = PackObjectReader{
            .allocator = allocator,
            .pack = pack,
            .object_reader = try pack.readObjectAt(offset),
        };
        return pack_object_reader;
    }

    pub fn reader(self: *PackObjectReader) Reader {
        return self.object_reader.reader();
    }

    pub fn deinit(self: *PackObjectReader) void {
        self.object_reader.deinit();
        self.pack.deinit();
        self.allocator.destroy(self);
    }
};

pub const Pack = struct {
    allocator: mem.Allocator,
    file: fs.File,
    header: Header,

    pub fn init(allocator: mem.Allocator, path: []const u8) !*Pack {
        const file = try fs.cwd().openFile(path, .{});
        try file.seekTo(0);
        const reader = file.reader();
        const signature = try reader.readBytesNoEof(4);
        const version = try reader.readIntBig(u32);
        const number_objects = try reader.readIntBig(u32);

        if (!mem.eql(u8, &signature, "PACK")) {
            return error.UnsupportedPackFile;
        }

        if (version != 2) {
            return error.UnsupportedPackVersion;
        }

        var pack = try allocator.create(Pack);
        pack.* = Pack {
            .allocator = allocator,
            .file = file,
            .header = Header {
                .signature = signature,
                .version = version,
                .number_objects = number_objects,
            },
        };

        return pack;
    }

    pub fn deinit(self: *Pack) void {
        self.file.close();
        self.allocator.destroy(self);
    }

    pub fn format(self: Pack, comptime fmt: []const u8, options: std.fmt.FormatOptions, out_stream: anytype) !void {
        _ = fmt;
        _ = options;

        try out_stream.print("Pack{{ signature = {s}, version = {d}, number_objects = {d} }}", .{ self.header.signature, self.header.version, self.header.number_objects });
    }

    pub fn readObjectAt(self: Pack, offset: usize) !ObjectReader {
        try self.file.seekTo(offset);
        const reader = self.file.reader();
        const object_header = try parseObjectHeader(reader);

        var decompressor = try std.compress.zlib.decompressStream(self.allocator, reader);
        errdefer decompressor.deinit();

        return ObjectReader{
            .decompressor = decompressor,
            .header = object_header,
            .offset = offset,
        };
    }

    pub fn iterator(self: *Pack) !ObjectIterator {
        return try ObjectIterator.init(self);
    }

    pub fn validate(self: *Pack) !void {
        try self.file.seekTo(0);
        const reader = self.file.reader();

        var hasher = std.crypto.hash.Sha1.init(.{});
        const writer = hasher.writer();

        const file_length = try self.file.getEndPos();
        const length_without_hash = file_length - 20;

        var bytes_written: usize = 0;
        var buffer: [4096]u8 = undefined;
        while (bytes_written < length_without_hash) {
            const bytes_remaining = length_without_hash - bytes_written;
            const to_read = if (bytes_remaining > 4096) 4096 else bytes_remaining;
            const bytes_read = try reader.read(buffer[0..to_read]);
            try writer.writeAll(buffer[0..bytes_read]);
            bytes_written += bytes_read;
        }
        const hash = hasher.finalResult();
        const footer_hash = try reader.readBytesNoEof(20);
        if (!mem.eql(u8, &hash, &footer_hash)) {
            return error.HashMismatch;
        }
    }
};

pub fn parseObjectHeader(reader: anytype) !ObjectHeader {
    var size: usize = 0;
    const first_byte = try reader.readByte();
    const first_bits: ObjectFirstBit = @bitCast(first_byte);
    const object_type = first_bits.type;
    size += first_bits.size;
    var more: bool = first_bits.more;
    var shifts: u6 = 4;
    while (more) {
        const byte = try reader.readByte();
        more = if (byte >> 7 == 0) false else true;
        const more_size_bits: u64 = byte & (0xFF >> 1);
        size += (more_size_bits << shifts);
        shifts += 7;
    }

    var delta_header: ?ObjectHeader.Delta = null;
    if (object_type == .ofs_delta) {
        delta_header = ObjectHeader.Delta{ .offset = try parseVariableLength(reader) };
    }
    if (object_type == .ref_delta) {
        delta_header = ObjectHeader.Delta{ .ref = try reader.readBytesNoEof(20) };
    }

    return ObjectHeader{
        .size = size,
        .type = object_type,
        .delta = delta_header,
    };
}

const ObjectFirstBit = packed struct(u8) {
    size: u4,
    type: PackObjectType,
    more: bool,
};



pub const ObjectIterator = struct {
    pack: *Pack,
    current_object_reader: ?ObjectReader = null,
    current_end_pos: usize,

    pub fn init(pack: *Pack) !ObjectIterator {
        // Reset to right after the header
        return ObjectIterator{
            .pack = pack,
            .current_end_pos = 12,
        };
    }

    pub fn next(self: *ObjectIterator) !?Entry {
        // Finish existing decompressor so we're at the end of the
        // current object
        if (self.current_object_reader) |*existing_reader| {
            existing_reader.deinit();
        }
        self.current_object_reader = null;

        // Account for the 20 byte pack sha1 checksum trailer
        if (self.current_end_pos + 20 == try self.pack.file.getEndPos()) {
            return null;
        }

        // Create new decompressor at current position, hash object
        // contents, reset decompressor and file position, pass new
        // decompressor to caller

        const object_begin = self.current_end_pos;

        var object_reader_hash = try self.pack.readObjectAt(object_begin);
        defer object_reader_hash.deinit();

        var hasher = std.crypto.hash.Sha1.init(.{});
        const hasher_writer = hasher.writer();
        var counting_writer = std.io.countingWriter(hasher_writer);

        // Create object header just like in loose object file.
        // These don't work for delta objects.
        try hasher_writer.print("{s} {d}\x00", .{ @tagName(object_reader_hash.header.type), object_reader_hash.header.size });

        var pump = std.fifo.LinearFifo(u8, .{ .Static = 4094 }).init();
        try pump.pump(object_reader_hash.reader(), counting_writer.writer());

        self.current_end_pos = try self.pack.file.getPos();

        if (counting_writer.bytes_written != object_reader_hash.header.size) {
            return error.PackObjectSizeMismatch;
        }

        const object_name = hasher.finalResult();

        // Create fresh reader for caller
        self.current_object_reader = try self.pack.readObjectAt(object_begin);

        return Entry{
            .offset = object_begin,
            .object_name = object_name,
            .object_reader = &self.current_object_reader.?,
        };
    }

    pub fn reset(self: *ObjectIterator) !void {
        try self.pack.file.seekTo(12);
    }

    pub fn deinit(self: *ObjectIterator) void {
        if (self.current_object_reader) |*current| {
            current.deinit();
        }
    }

    pub const Entry = struct {
        offset: usize,
        object_name: [20]u8,
        object_reader: *ObjectReader,
    };
};

pub const Header = struct {
    signature: [4]u8,
    version: u32,
    number_objects: u32,
};

pub const PackObjectType = enum(u3) {
    commit = 1,
    tree = 2,
    blob = 3,
    tag = 4,
    ofs_delta = 6,
    ref_delta = 7,
};

pub const ObjectReader = struct {
    decompressor: Decompressor,
    header: ObjectHeader,
    offset: u64,

    pub const Decompressor = std.compress.zlib.DecompressStream(fs.File.Reader);
    pub const Reader = Decompressor.Reader;
    const Self = @This();

    pub fn reader(self: *ObjectReader) Reader {
        return self.decompressor.reader();
    }

    pub fn deinit(self: *ObjectReader) void {
        self.decompressor.deinit();
    }
};


pub const ObjectHeader = struct {
    size: usize,
    type: PackObjectType,
    delta: ?Delta,

    const Delta = union(enum) {
        offset: usize,
        ref: [20]u8,
    };
};
