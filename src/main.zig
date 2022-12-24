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
        const repo_root = try findRepoRoot(allocator);
        defer allocator.free(repo_root);

        std.debug.print("Repo root: {s}\n", .{ repo_root });
        const index = try readIndex(allocator, repo_root);
        std.debug.print("Signature: {s}\nNum Entries: {d}\nVersion: {d}\n", .{ index.header.signature, index.header.entries, index.header.version });
        for (index.entries) |entry| {
            std.debug.print(
                \\Entry:
                    \\ Mode: {o}
                    \\ Hash: {s}
                    \\ Size: {d}
                    \\ Path: {s}
                    \\
                    ,
                .{
                    @bitCast(u32, entry.mode),
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
    const git_dir_path = try fs.path.join(allocator, &.{ path, ".git" });
    defer allocator.free(git_dir_path);
    const hash = try saveObject(allocator, git_dir_path, "test\n", .blob);
    std.debug.print("Hash: {x}\n", .{ std.fmt.fmtSliceHexLower(&hash) });
    const obj_header = try loadObject(allocator, git_dir_path, &hash, std.io.getStdOut().writer());
    std.debug.print("{}\n", .{ obj_header });
    const made_up_entry = Index.Entry{
        .ctime_s = 1,
        .ctime_n = 1,
        .mtime_s = 1,
        .mtime_n = 1,
        .dev = 39,
        .ino = 1,
        .mode = Index.Mode{
            .unix_permissions = 0o644,
            .unused = 0,
            .object_type = .regular_file,
            .padding = 0,
        },
        .uid = 1000,
        .gid = 1000,
        .file_size = 12,
        .object_name = [_]u8{0} ** 20,
        .flags = Index.Flags{
            .name_length = 13,
            .stage = 0,
            .extended = false,
            .assume_valid = false,

        },
        .extended_flags = null,
        .path = "testing_file",
    };
    const made_up_index = Index{
        .allocator = allocator,
        .header = Index.Header{
            .signature = "DIRC".*,
            .version = 2,
            .entries = 1,
        },
        .entries = &.{
            made_up_entry,
        }
    };
    try writeIndex(allocator, path, made_up_index);
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

pub fn saveObject(allocator: mem.Allocator, git_dir_path: []const u8, data: []const u8, obj_type: ObjectType) ![20]u8 {
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

    return digest;
}

pub fn loadObject(allocator: mem.Allocator, git_dir_path: []const u8, hash: *const [20]u8, writer: anytype) !ObjectHeader {
    const hex_digest = try std.fmt.allocPrint(allocator, "{s}", .{ std.fmt.fmtSliceHexLower(hash) });
    defer allocator.free(hex_digest);

    const path = try fs.path.join(allocator, &.{ git_dir_path, "objects", hex_digest[0..2], hex_digest[2..] });
    defer allocator.free(path);

    const file = try fs.cwd().openFile(path, .{});
    defer file.close();

    var decompressor = try std.compress.zlib.zlibStream(allocator, file.reader());
    defer decompressor.deinit();
    const reader = decompressor.reader();

    const header = try reader.readUntilDelimiterAlloc(allocator, 0, 1024);
    defer allocator.free(header);

    var header_iter = mem.split(u8, header, " ");
    const object_type = std.meta.stringToEnum(ObjectType, header_iter.first()) orelse return error.InvalidObjectType;
    const size = blk: {
        const s = header_iter.next() orelse return error.InvalidObjectSize;
        const n = try std.fmt.parseInt(u32, s, 10);
        break :blk n;
    };

    var fifo = std.fifo.LinearFifo(u8, .{ .Static = 4096 }).init();
    try fifo.pump(reader, writer);

    return ObjectHeader{
        .@"type" = object_type,
        .size = size,
    };
}

pub const ObjectHeader = struct {
    @"type": ObjectType,
    size: u32,
};

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
    const index_signature = index_data[index_data.len-20..];

    if (!mem.eql(u8, &index_hash, index_signature)) {
        return error.InvalidIndexSignature;
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
                if (try index_reader.readByte() != 0) {
                    return error.InvalidEntryPathPadding;
                }
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

pub fn writeIndex(allocator: mem.Allocator, repo_path: []const u8, index: Index) !void {
    const index_path = try fs.path.join(allocator, &.{ repo_path, ".git", "index" });
    defer allocator.free(index_path);
    const index_file = try fs.cwd().createFile(index_path, .{ .read = true });
    defer index_file.close();

    const index_writer = index_file.writer();

    try index_writer.writeAll(&index.header.signature);
    try index_writer.writeIntBig(u32, index.header.version);
    try index_writer.writeIntBig(u32, @truncate(u32, index.entries.len));

    var entries: []*const Index.Entry = try allocator.alloc(*Index.Entry, index.entries.len);
    defer allocator.free(entries);

    for (index.entries) |entry, idx| {
        entries[idx] = &entry;
    }

    std.sort.sort(*const Index.Entry, entries, {}, sortEntries);

    for (entries) |entry| {
        var counter = std.io.countingWriter(index_writer);
        const counting_writer = counter.writer();

        try counting_writer.writeIntBig(u32, entry.ctime_s);
        try counting_writer.writeIntBig(u32, entry.ctime_n);
        try counting_writer.writeIntBig(u32, entry.mtime_s);
        try counting_writer.writeIntBig(u32, entry.mtime_n);
        try counting_writer.writeIntBig(u32, entry.dev);
        try counting_writer.writeIntBig(u32, entry.ino);
        try counting_writer.writeIntBig(u32, @bitCast(u32, entry.mode));
        try counting_writer.writeIntBig(u32, entry.uid);
        try counting_writer.writeIntBig(u32, entry.gid);
        try counting_writer.writeIntBig(u32, entry.file_size);
        try counting_writer.writeAll(&entry.object_name);

        try counting_writer.writeIntBig(u16, @bitCast(u16, entry.flags));
        if (index.header.version > 2 and entry.flags.extended and entry.extended_flags != null) {
            try counting_writer.writeIntBig(u16, @bitCast(u16, entry.extended_flags.?));
        }

        try counting_writer.writeAll(entry.path);
        try counting_writer.writeByte(0);

        const entry_length = counter.bytes_written;
        if (index.header.version < 4) {
            const extra_zeroes = (8 - (entry_length % 8)) % 8;
            var extra_zeroes_idx: usize = 0;
            while (extra_zeroes_idx < extra_zeroes) : (extra_zeroes_idx += 1) {
                try counting_writer.writeByte(0);
            }
        }
    }

    try index_file.seekTo(0);
    var hasher = std.crypto.hash.Sha1.init(.{});
    var pump_fifo = std.fifo.LinearFifo(u8, .{ .Static = 4086 }).init();
    try pump_fifo.pump(index_file.reader(), hasher.writer());
    var index_hash: [20]u8 = undefined;
    hasher.final(&index_hash);

    try index_file.seekFromEnd(0);
    try index_writer.writeAll(&index_hash);
}

pub fn sortEntries(context: void, lhs: *const Index.Entry, rhs: *const Index.Entry) bool {
    _ = context;
    return mem.lessThan(u8, lhs.path, rhs.path);
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
        unused: u3 = 0,
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

test "ref all" {
    std.testing.refAllDecls(@This());
}
