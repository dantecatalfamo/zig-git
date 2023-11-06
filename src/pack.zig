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
        try self.file.seekTo(offset);
        const reader = self.file.reader();
        const object_header = try parseObjectHeader(reader);

        // TODO get these to work
        if (object_header.type == .ofs_delta or object_header.type == .ref_delta) {
            std.debug.print("Cannot read {s} yet\n", .{ @tagName(object_header.type) });
            std.debug.print("Size: {d}\n", .{ object_header.size });
            if (object_header.type == .ofs_delta) {
                const base_offset = try parseVariableLength(reader);
                std.debug.print("Base offset: {d}\n", .{ base_offset });
            } else {
                const ref_object_name = try reader.readBytesNoEof(20);
                std.debug.print("Ref object name: {s}\n", .{ std.fmt.fmtSliceHexLower(&ref_object_name) });
            }
            // return error.Unimplemented;
        }

        var decompressor = try std.compress.zlib.decompressStream(self.allocator, reader);
        errdefer decompressor.deinit();

        return ObjectReader{
            .decompressor = decompressor,
            .file = self.file,
            .header = object_header,
        };
    }

    pub fn iterator(self: *Pack) !ObjectIterator {
        return try ObjectIterator.init(self);
    }
};

pub fn parseDeltaInstructions(allocator: mem.Allocator, size: usize, reader: anytype) void {
    _ = size;
    var decompressor = try std.compress.zlib.decompressStream(allocator, reader);
    const decompressor_reader = decompressor.reader();
    var deltas = std.ArrayList(Delta).init(allocator);
    _ = deltas;

    const first_byte = try reader.readByte();
    const first_bit = first_byte >> 7;
    const remainder_bits = first_byte & 0b01111111;
    _ = remainder_bits;
    if (first_bit == 1) {
        // Copy
        var offset: u32 = 0;
        _ = offset;
        var offset_size: u32 = 0;
        _ = offset_size;
    } else {
        // Data
    }
    _ = decompressor_reader;
}

pub const DeltaInstructions = struct {
    allocator: mem.Allocator,
    deltas: []Delta,

    pub fn deinit(self: DeltaInstructions) void {
        for (self.deltas) |delta| {
            switch (delta) {
                .copy => {},
                .data => |dlt| { self.allocator.free(dlt); }
            }
        }
        self.allocator.free(self.deltas);
    }
};

pub const Delta = union(enum) {
    copy: Copy,
    data: []const u8,

    pub const Copy = struct {
        offset: u32,
        size: u32,
    };
};

pub fn parseVariableLength(reader: anytype) !usize {
    var size: usize = 0;
    var shift: u6 = 0;
    var more = true;
    while (more) {
        var byte: VariableLengthByte = @bitCast(try reader.readByte());
        size += @as(usize, byte.size) << shift;
        shift += 7;
        more = byte.more;
    }
    return size;
}

const VariableLengthByte = packed struct(u8) {
    size: u7,
    more: bool,
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

    return ObjectHeader{
        .size = size,
        .type = object_type,
    };
}

const ObjectFirstBit = packed struct(u8) {
    size: u4,
    type: ObjectType,
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

        if (try self.pack.file.getPos() == try self.pack.file.getEndPos()) {
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

        // FIXME This works for normal objects, we don't know how to
        // handle deltas yet and this might need to change
        //
        // Create object header just like in loose object file
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
