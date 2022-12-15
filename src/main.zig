const std = @import("std");
const os = std.os;
const mem = std.mem;
const fs = std.fs;
const zlibStreamWriter = @import("zlib_writer.zig").zlibStreamWriter;

pub fn main() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    var allocator = gpa.allocator();
    defer _ = gpa.deinit();

    var args = std.process.args();
    _ = args.next();
    const path = args.next();
    if (path == null) {
        std.debug.print("No path privided\n", .{});
    }
    try initialize(allocator, path.?);
    std.debug.print("initialized empty repository {s}\n", .{ path.? });
    try os.chdir(path.?);
    try saveObject(allocator, "test", .blob);
}

pub fn initialize(allocator: mem.Allocator, repo_path: []const u8) !void {
    const bare_path = try fs.path.join(allocator, &.{ repo_path, ".git" });
    defer allocator.free(bare_path);

    try fs.cwd().makeDir(repo_path);
    try initializeBare(allocator, bare_path);
}

pub fn initializeBare(allocator: mem.Allocator, repo_path: []const u8) !void {
    try fs.cwd().makeDir(repo_path);
    inline for (.{ "objects", "refs", "refs/heads" }) |dir| {
        const dir_path = try fs.path.join(allocator, &.{ repo_path, dir });
        defer allocator.free(dir_path);
        try fs.cwd().makeDir(dir_path);
    }
    const head_path = try fs.path.join(allocator, &.{ repo_path, "HEAD" });
    defer allocator.free(head_path);

    const head = try fs.cwd().createFile(head_path, .{});
    try head.writeAll("ref: refs/heads/master");
    defer head.close();
}

pub fn hashObject(data: []const u8, obj_type: ObjectType, digest: *[20]u8) void {
    var hash = std.crypto.hash.Sha1.init(.{});
    const writer = hash.writer();
    try writer.print("{s} {d}\x00", .{ @tagName(obj_type), data.len });
    try writer.writeAll(data);
    hash.final(digest);
}

pub fn saveObject(allocator: mem.Allocator, data: []const u8, obj_type: ObjectType) !void {
    var digest: [20]u8 = undefined;
    hashObject(data, obj_type, &digest);

    const hex_digest = try std.fmt.allocPrint(allocator, "{s}", .{ std.fmt.fmtSliceHexLower(&digest) });
    defer allocator.free(hex_digest);

    const path = try fs.path.join(allocator, &.{ ".git", "objects", hex_digest[0..2], hex_digest[2..] });
    defer allocator.free(path);
    try fs.cwd().makePath(fs.path.dirname(path).?);

    const file = try fs.cwd().createFile(path, .{});
    defer file.close();

    var compressor = try zlibStreamWriter(allocator, file.writer(), .{});
    defer compressor.deinit();

    const writer = compressor.writer();
    try writer.print("{s} {d}\x00", .{ @tagName(obj_type), data.len });
    try writer.writeAll(data);
    try compressor.close();
}

pub const ObjectType = enum {
    blob,
    commit,
    tree,
};

pub const IndexHeader = struct {
    signature: [4]u8,
    version: u32,
    entries: u32,
};

pub const IndexEntry = struct {
    ctime_s: u32,
    ctime_n: u32,
    mtime_s: u32,
    mtime_n: u32,
    dev: u32,
    ino: u32,
    mode: u32,
    obj_type: u4,
    unused: u3,
    unix_permissions: u9,
    uid: u32,
    gid: u32,
    file_size: u32,
    hash: [20]u8,
    flags: u16,
    path: []const u8,
};
