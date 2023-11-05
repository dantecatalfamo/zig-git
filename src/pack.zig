const std = @import("std");
const debug = std.debug;
const fs = std.fs;
const mem = std.mem;
const os = std.os;
const testing = std.testing;

const Pack = struct {
    allocator: mem.Allocator,
    file: fs.File,
    header: Header,

    pub fn init(allocator: mem.Allocator, file: fs.File) !Pack {
        try file.seekTo(0);
        const reader = file.reader();
        const signature = try reader.readBytesNoEof(4);
        const version = try reader.readIntBig(u32);
        const number_objects = try reader.readIntBig(u32);

        return Pack {
            .allocator = allocator,
            .file = file,
            .header = Header {
                .signature = signature,
                .version = version,
                .number_objects = number_objects,
            },
        };
    }

    const Header = struct {
        signature: [4]u8,
        version: u32,
        number_objects: u32,
    };
};
