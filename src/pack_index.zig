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

    pub fn find(self: PackIndex, object_name: [20]u8) !?usize {
        if (self.version == 1) {
            // TODO index version 1 lookup
            return error.Unimplemented;
        }
        if (try self.version2FindObjectIndex(object_name)) |index| {
            return try self.version2OffsetAtIndex(index);
        }
        return null;
    }

    pub fn version2FindObjectIndex(self: PackIndex, object_name: [20]u8) !?usize {
        var bottom: u32 = 0;
        var top: u32 = self.fanout_table[object_name[0]];
        while (top != bottom) {
            const halfway: u32 = ((top - bottom) / 2) + bottom;
            const halfway_object_name = try self.version2ObjectNameAtIndex(halfway);
            if (mem.eql(u8, &object_name, &halfway_object_name)) {
                return halfway;
            }
            if (mem.lessThan(u8, &object_name, &halfway_object_name)) {
                top = halfway;
            } else {
                bottom = halfway;
            }
        }
        const last_object_name = try self.version2ObjectNameAtIndex(top);
        if (mem.eql(u8, &object_name, &last_object_name)) {
            return top;
        }
        return null;
    }

    pub fn version2ObjectNameAtIndex(self: PackIndex, index: usize) ![20]u8 {
        const num_entries = self.fanout_table[255];
        if (index > num_entries) {
            return error.IndexOutOfBounds;
        }
        const end_of_fanout = 4 + 4 + (256 * 4);
        const index_position = end_of_fanout + (index * 20);
        try self.file.seekTo(index_position);
        return try self.file.reader().readBytesNoEof(20);
    }

    pub fn version2OffsetAtIndex(self: PackIndex, index: usize) !u64 {
        const total_entries = self.fanout_table[256];
        if (index > total_entries) {
            return error.IndexOutOfBounds;
        }
        const reader = self.file.reader();
        const end_of_fanout = 4 + 4 + (256 * 4);
        const end_of_object_names = end_of_fanout + (total_entries * 20);
        const end_of_crc = end_of_object_names + (total_entries * 4);
        const end_of_offset32 = end_of_crc + (total_entries * 4);

        const index32_pos = end_of_crc + (4 * index);
        try self.file.seekTo(index32_pos);
        const index32 = try reader.readIntBig(u32);
        const index32_value = index32 & (std.math.maxInt(u32) >> 1);
        if (index32 >> 31 == 0) {
            return index32_value;
        }

        const index64_pos = end_of_offset32 + (index32_value * 8);
        try self.file.seekTo(index64_pos);
        return try reader.readIntBig(u64);
    }
};
