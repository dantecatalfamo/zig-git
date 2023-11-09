const std = @import("std");
const debug = std.debug;
const fs = std.fs;
const mem = std.mem;
const os = std.os;
const testing = std.testing;

const Tree = @import("tree.zig").Tree;

/// Returns a repo's .git directory path
pub fn repoToGitDir(allocator: mem.Allocator, repo_path: []const u8) ![]const u8 {
    return try fs.path.join(allocator, &.{ repo_path, ".git" });
}

/// Find the root of the repository, caller responsible for memory.
pub fn findRepoRoot(allocator: mem.Allocator) ![]const u8 {
    var path_buffer: [fs.MAX_PATH_BYTES]u8 = undefined;
    var dir = fs.cwd();

    while (true) {
        const absolute_path = try dir.realpath(".", &path_buffer);

        dir.access(".git", .{}) catch |err| {
            switch (err) {
                error.FileNotFound => {
                    if (mem.eql(u8, absolute_path, "/")) {
                        return error.NoGitRepo;
                    }

                    var new_dir = try dir.openDir("..", .{});
                    // Can't close fs.cwd() or we get BADF
                    if (dir.fd != fs.cwd().fd) {
                        dir.close();
                    }

                    dir = new_dir;
                    continue;
                },
                else => return err,
            }
        };

        if (dir.fd != fs.cwd().fd) {
            dir.close();
        }
        return allocator.dupe(u8, absolute_path);
    }
}

/// Returns the binary object name for a given hex string
pub fn hexDigestToObjectName(hash: []const u8) ![20]u8 {
    var buffer: [20]u8 = undefined;
    const output = try std.fmt.hexToBytes(&buffer, hash);
    if (output.len != 20) {
        return error.IncorrectLength;
    }
    return buffer;
}

/// lessThan for strings for sorting
pub fn lessThanStrings(context: void, lhs: []const u8, rhs: []const u8) bool {
    _ = context;
    return mem.lessThan(u8, lhs, rhs);
}

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

pub const StringList = std.ArrayList([]const u8);
pub const ObjectNameList = std.ArrayList([20]u8);
