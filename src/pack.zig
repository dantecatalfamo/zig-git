const std = @import("std");
const debug = std.debug;
const fs = std.fs;
const mem = std.mem;
const os = std.os;
const testing = std.testing;

pub const Pack = struct {
    allocator: mem.Allocator,
    file: fs.File,
    header: Header,

    pub fn init(allocator: mem.Allocator, file: fs.File) !*Pack {
        try file.seekTo(0);
        const reader = file.reader();
        const signature = try reader.readBytesNoEof(4);
        const version = try reader.readIntBig(u32);
        const number_objects = try reader.readIntBig(u32);

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
        self.allocator.destroy(self);
    }

    pub fn format(self: Pack, comptime fmt: []const u8, options: std.fmt.FormatOptions, out_stream: anytype) !void {
        _ = fmt;
        _ = options;

        try out_stream.print("Pack{{ signature = {s}, version = {d}, number_objects = {d} }}", .{ self.header.signature, self.header.version, self.header.number_objects });
    }

    pub fn readObjectAt(self: Pack, offset: usize) !*ObjectReader {
        var size: u64 = 0;
        try self.file.seekTo(offset);
        const reader = self.file.reader();
        const first_byte = try reader.readByte();
        const object_type: ObjectType = @enumFromInt(first_byte >> 5);
        size += first_byte & (0xFF >> 3);
        var more = true;
        while (more) {
            const byte = try reader.readByte();
            more = if ((byte & (1 << 7)) == 0) false else true;
            size += byte & (0xFF >> 1);
        }

        var decompressor = try std.compress.zlib.decompressStream(self.allocator, reader);
        errdefer decompressor.deinit();

        const header = ObjectHeader{
            .size = size,
            .type = object_type,
        };

        var object_reader = try self.allocator.create(ObjectReader);
        errdefer self.allocator.destroy(object_reader);

        object_reader.* = ObjectReader{
            .decompressor = decompressor,
            .file = self.file,
            .header = header,
        };

        return object_reader;
    }
};


pub const Header = struct {
    signature: [4]u8,
    version: u32,
    number_objects: u32,
};

pub const ObjectType = enum(u3) {
    commit = 1,
    tree = 2,
    blob = 3,
    tag = 4,
    ofs_delta = 6,
    ref_delta = 7,
};

pub const ObjectReader = struct {
    decompressor: Decompressor,
    file: fs.File,
    header: ObjectHeader,

    const Decompressor = std.compress.zlib.DecompressStream(fs.File.Reader);
    const Reader = Decompressor.Reader;
    const Self = @This();

    pub fn reader(self: *ObjectReader) Reader {
        return self.decompressor.reader();
    }

    pub fn deinit(self: *ObjectReader) void {
        self.decompressor.deinit();
        self.decompressor.allocator.destroy(self);
    }
};


pub const ObjectHeader = struct {
    size: usize,
    type: ObjectType,
};
