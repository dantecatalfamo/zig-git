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
    const maybe_path = args.next();
    if (maybe_path == null) {
        std.debug.print("No path privided\n", .{});
        const index = try readIndex(allocator, ".");
        std.debug.print("Signature: {s}\nNum Entries: {d}\nVersion: {d}\n", .{ index.header.signature, index.header.entries, index.header.version });
        for (index.entries) |entry| {
            std.debug.print(
                \\Entry:
                    \\ Mode: {}
                    \\ Hash: {s}
                    \\ Size: {d}
                    \\ Path: {s}
                    \\
                    ,
                .{
                    entry.mode,
                    std.fmt.fmtSliceHexLower(&entry.object_name),
                    entry.file_size,
                    entry.path
            });
            std.debug.print("{}\n", .{ entry });
        }
        defer index.deinit();
        return;
    }
    const path = maybe_path.?;
    try initialize(allocator, path);
    std.debug.print("initialized empty repository {s}\n", .{ path });
    try os.chdir(path);
    const git_dir_path = try fs.path.join(allocator, &.{ path, ".git" });
    defer allocator.free(git_dir_path);
    try saveObject(allocator, git_dir_path, "test", .blob);
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

pub fn saveObject(allocator: mem.Allocator, git_dir_path: []const u8, data: []const u8, obj_type: ObjectType) !void {
    var digest: [20]u8 = undefined;
    hashObject(data, obj_type, &digest);

    const hex_digest = try std.fmt.allocPrint(allocator, "{s}", .{ std.fmt.fmtSliceHexLower(&digest) });
    defer allocator.free(hex_digest);

    const path = try fs.path.join(allocator, &.{ git_dir_path, "objects", hex_digest[0..2], hex_digest[2..] });
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

pub fn readIndex(allocator: mem.Allocator, repo_path: []const u8) !*Index {
    const index_path = try fs.path.join(allocator, &.{ repo_path, ".git", "index" });
    defer allocator.free(index_path);

    const index_file = try fs.cwd().openFile(index_path, .{});
    const index_data = try index_file.readToEndAlloc(allocator, std.math.maxInt(usize));
    defer allocator.free(index_data);
    var index_hash: [20]u8 = undefined;
    std.crypto.hash.Sha1.hash(index_data[0..index_data.len-20], &index_hash, .{});
    if (mem.eql(u8, &index_hash, index_data[index_data.len-20..])) {
        // return error.InvalidIndexSignature;
    }

    var index_buffer = std.io.fixedBufferStream(index_data[0..index_data.len-20]);
    const index_reader = index_buffer.reader();

    const header = Index.Header{
        .signature = try index_reader.readBytesNoEof(4),
        .version = try index_reader.readIntBig(u32),
        .entries = try index_reader.readIntBig(u32),
    };

    if (!mem.eql(u8, "DIRC", &header.signature)) {
        return error.UnsupportedIndexSignature;
    }

    if (header.version > 3) {
        return error.UnsupportedIndexVersion;
    }

    var entries = std.ArrayList(Index.Entry).init(allocator);

    var idx: usize = 0;
    while (idx < header.entries) : (idx += 1) {
        const entry_begin_pos = index_buffer.pos;

        const ctime_s = try index_reader.readIntBig(u32);
        const ctime_n = try index_reader.readIntBig(u32);
        const mtime_s = try index_reader.readIntBig(u32);
        const mtime_n = try index_reader.readIntBig(u32);
        const dev = try index_reader.readIntBig(u32);
        const ino = try index_reader.readIntBig(u32);
        const mode = @bitCast(Index.Mode, try index_reader.readIntBig(u32));

        // const object_type = @truncate(u4, mode >> 12);
        // const unused = @truncate(u3, mode >> 9);
        // const unix_permissions = @truncate(u9, mode);

        const uid = try index_reader.readIntBig(u32);
        const gid = try index_reader.readIntBig(u32);
        const file_size = try index_reader.readIntBig(u32);
        const object_name = try index_reader.readBytesNoEof(20);

        const flags = @bitCast(Index.Flags, try index_reader.readIntBig(u16));
        const extended_flags = blk: {
            if (header.version > 2 and flags.extended) {
                const extra_flgs = try index_reader.readIntBig(u16);
                break :blk @bitCast(Index.ExtendedFlags, extra_flgs);
            } else {
                break :blk null;
            }
        };

        const path = try index_reader.readUntilDelimiterAlloc(allocator, 0, std.math.maxInt(usize));

        const entry_end_pos = index_buffer.pos;
        const entry_size = entry_end_pos - entry_begin_pos;

        if (header.version < 4) {
            const extra_zeroes = (8 - (entry_size % 8)) % 8;
            var extra_zero_idx: usize = 0;
            while (extra_zero_idx < extra_zeroes) : (extra_zero_idx += 1) {
                _ = try index_reader.readByte();
            }
        }

        const entry = Index.Entry{
            .ctime_s = ctime_s,
            .ctime_n = ctime_n,
            .mtime_s = mtime_s,
            .mtime_n = mtime_n,
            .dev = dev,
            .ino = ino,
            .mode = mode,
            // .object_type = @intToEnum(Index.EntryType, object_type),
            // .unused = unused,
            // .unix_permissions = unix_permissions,
            .uid = uid,
            .gid = gid,
            .file_size = file_size,
            .object_name = object_name,
            .flags = flags,
            .extended_flags = extended_flags,
            .path = path,
        };

        try entries.append(entry);
    }

    const index = try allocator.create(Index);
    index.* = Index{
        .allocator = allocator,
        .header = header,
        .entries = try entries.toOwnedSlice(),
    };
    return index;
}

// https://git-scm.com/docs/index-format
pub const Index = struct {
    allocator: mem.Allocator,
    header: Header,
    entries: []const Entry,

    pub fn deinit(self: *const Index) void {
        for (self.entries) |entry| {
            self.allocator.free(entry.path);
        }
        self.allocator.free(self.entries);
        self.allocator.destroy(self);
    }

    pub const Header = struct {
        signature: [4]u8,
        version: u32,
        entries: u32,
    };

    pub const Entry = struct {
        ctime_s: u32,
        ctime_n: u32,
        mtime_s: u32,
        mtime_n: u32,
        dev: u32,
        ino: u32,
        mode: Mode,
        uid: u32,
        gid: u32,
        file_size: u32,
        object_name: [20]u8,
        flags: Flags,
        extended_flags: ?ExtendedFlags, // v3+ and extended only
        path: []const u8,
    };

    pub const Mode = packed struct (u32) {
        unix_permissions: u9,
        unused: u3,
        object_type: EntryType,
        padding: u16 = 0,
    };

    pub const EntryType = enum(u4) {
        regular_file = 0b1000,
        symbolic_link = 0b1010,
        gitlink = 0b1110,
    };

    pub const Flags = packed struct(u16) {
        name_length: u12,
        stage: u2,
        extended: bool,
        assume_valid: bool,
    };

    pub const ExtendedFlags = packed struct(u16) {
        unused: u13,
        intent_to_add: bool,
        skip_worktree: bool,
        reserved: bool,
    };
};
