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
};
