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

    pub fn readObjectAt(self: Pack, offset: usize) !ObjectReader {
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

        return ObjectReader{
            .decompressor = decompressor,
            .file = self.file,
            .header = header,
        };
    }

    pub fn iterator(self: *Pack) !ObjectIterator {
        return try ObjectIterator.init(self);
    }
};


pub const ObjectIterator = struct {
    pack: *Pack,
    current_object_reader: ?ObjectReader = null,

    pub fn init(pack: *Pack) !ObjectIterator {
        // Reset to right after the header
        try pack.file.seekTo(12);

        return ObjectIterator{
            .pack = pack,
        };
    }

    pub fn next(self: *ObjectIterator) !?Entry {
        // Finish existing decompressor so we're at the end of the
        // current object
        if (self.current_object_reader) |*existing_reader| {
            var waste_buffer: [4096]u8 = undefined;
            const reader = existing_reader.reader();
            while (try reader.read(&waste_buffer) != 0) {}
            existing_reader.deinit();
        }
        self.current_object_reader = null;

        if (try self.pack.file.getPos() == try self.pack.file.getEndPos()) {
            return null;
        }

        // Create new decompressor at current position, hash object
        // contents, reset decompressor and file position, pass new
        // decompressor to caller

        const object_begin = try self.pack.file.getPos();

        var hasher = std.crypto.hash.Sha1.init(.{});
        const hash_writer = hasher.writer();
        _ = hash_writer;

        var object_reader_hash = try self.pack.readObjectAt(object_begin);
        defer object_reader_hash.deinit();

        var pump = std.fifo.LinearFifo(u8, .{ .Static = 4094 }).init();
        try pump.pump(object_reader_hash.reader(), hasher.writer());

        const object_name = hasher.finalResult();

        self.current_object_reader = try self.pack.readObjectAt(object_begin);

        return Entry{
            .object_name = object_name,
            .object_reader = &self.current_object_reader.?,
        };
    }

    pub fn reset(self: *ObjectIterator) !void {
        try self.pack.file.seekTo(12);
    }

    pub const Entry = struct {
        object_name: [20]u8,
        object_reader: *ObjectReader,
    };
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
    }
};


pub const ObjectHeader = struct {
    size: usize,
    type: ObjectType,
};