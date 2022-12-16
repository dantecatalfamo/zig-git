//
// Decompressor for ZLIB data streams (RFC1950)

const std = @import("std");
const io = std.io;
const fs = std.fs;
const mem = std.mem;
const deflate = std.compress.deflate;

pub const CompressionLevel = enum (u2) {
    fastest = 0,
    fast = 1,
    default = 2,
    maximum = 3,
};

pub const CompressionOptions = struct {
    level: CompressionLevel = .default,
};

pub fn ZlibStreamWriter(comptime WriterType: type) type {
    return struct {
        const Self = @This();

        const Error = WriterType.Error ||
            deflate.Compressor(WriterType).Error;
        pub const Writer = io.Writer(*Self, Error, write);

        allocator: mem.Allocator,
        deflator: deflate.Compressor(WriterType),
        in_writer: WriterType,
        hasher: std.hash.Adler32,

        fn init(allocator: mem.Allocator, dest: WriterType, options: CompressionOptions) !Self {
            // Zlib header format is specified in RFC1950
            const CM: u4 = 8;
            const CINFO: u4 = 7;
            const CMF: u8 = (@as(u8, CINFO) << 4) | CM;

            const FLEVEL: u2 = @enumToInt(options.level);
            const FDICT: u1 = 0;
            const FCHECK: u5 = 28;
            const FLG = (@as(u8, FLEVEL) << 6) | (@as(u8, FDICT) << 5) | FCHECK;

            const compression_level: deflate.Compression = switch (options.level) {
                .fastest => .no_compression,
                .fast    => .best_speed,
                .default => .default_compression,
                .maximum => .best_compression,
            };

            try dest.writeAll(&.{ CMF, FLG });

            return Self{
                .allocator = allocator,
                .deflator = try deflate.compressor(allocator, dest, .{ .level = compression_level }),
                .in_writer = dest,
                .hasher = std.hash.Adler32.init(),
            };
        }

        pub fn write(self: *Self, bytes: []const u8) Error!usize {
            if (bytes.len == 0) {
                return 0;
            }

            const w = try self.deflator.write(bytes);

            if (w != 0) {
                self.hasher.update(bytes[0..w]);
                return w;
            }

            return 0;
        }

        pub fn writer(self: *Self) Writer {
            return .{ .context = self };
        }

        pub fn deinit(self: *Self) void {
            self.deflator.deinit();
        }

        pub fn close(self: *Self) !void {
            const hash = self.hasher.final();
            try self.deflator.close();
            try self.in_writer.writeIntBig(u32, hash);
        }
    };
}

pub fn zlibStreamWriter(allocator: mem.Allocator, writer: anytype, options: CompressionOptions) !ZlibStreamWriter(@TypeOf(writer)) {
    return ZlibStreamWriter(@TypeOf(writer)).init(allocator, writer, options);
}
