const std = @import("std");
const debug = std.debug;
const fs = std.fs;
const mem = std.mem;
const os = std.os;
const testing = std.testing;

pub const PackIndex = struct {
    file: fs.File,
    version: u32,
    fanout_table: [256]u32,

    pub fn init(file: fs.File) !PackIndex {
        try file.seekTo(0);
        const reader = file.reader();
        var fanout: [256]u32 = undefined;
        var version: u32 = 0;

        const magic_number = try reader.readBytesNoEof(4);
        if (mem.eql(u8, &magic_number, "\xfftOc")) {
            version = try reader.readIntBig(u32);
            fanout[0] = try reader.readIntBig(u32);
        } else {
            version = 1;
            fanout[0] = std.mem.readIntBig(u32, &magic_number);
        }
        std.debug.print("Version {d} pack\n", .{ version });

        for (1..256) |i| {
            fanout[i] = try reader.readIntBig(u32);
        }

        return PackIndex{
            .file = file,
            .version = version,
            .fanout_table = fanout,
        };
    }
};
