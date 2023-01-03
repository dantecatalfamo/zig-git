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

    const subcommand = args.next() orelse {
        std.debug.print("No subcommand specified. Available subcommands:\ninit\nindex\nadd\n", .{});
        return error.NoSubcommand;
    };

    if (mem.eql(u8, subcommand, "index")) {
        const repo_root = try findRepoRoot(allocator);
        defer allocator.free(repo_root);

        std.debug.print("Repo root: {s}\n", .{ repo_root });
        const index = try readIndex(allocator, repo_root);
        std.debug.print("Signature: {s}\nNum Entries: {d}\nVersion: {d}\n", .{ index.header.signature, index.header.entries, index.header.version });
        for (index.entries.items) |entry| {
            std.debug.print("{}\n", .{ entry });
        }
        defer index.deinit();
        return;

    } else if (mem.eql(u8, subcommand, "init")) {
        const path = blk: {
            if (args.next()) |valid_path| {
                break :blk valid_path;
            } else {
                break :blk ".";
            }
        };
        try initialize(allocator, path);
        std.debug.print("initialized empty repository {s}\n", .{ path });

    } else if (mem.eql(u8, subcommand, "add")) {
        const file_path = blk: {
            if (args.next()) |valid_path| {
                break :blk valid_path;
            }
            std.debug.print("Must specify file path\n", .{});
            return error.NoFilePath;
        };

        const repo_path = try findRepoRoot(allocator);
        defer allocator.free(repo_path);

        try addFileToIndex(allocator, repo_path, file_path);
    }
}

pub fn initialize(allocator: mem.Allocator, repo_path: []const u8) !void {
    const bare_path = try fs.path.join(allocator, &.{ repo_path, ".git" });
    defer allocator.free(bare_path);

    try fs.cwd().makePath(repo_path);
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
    try head.writeAll("ref: refs/heads/master\n");
    defer head.close();
}

pub fn hashObject(data: []const u8, obj_type: ObjectType, digest: *[20]u8) void {
    var hash = std.crypto.hash.Sha1.init(.{});
    const writer = hash.writer();
    try writer.print("{s} {d}\x00", .{ @tagName(obj_type), data.len });
    try writer.writeAll(data);
    hash.final(digest);
}

// TODO Maybe rewrite to use a reader interface instead of a data slice
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

pub fn loadObject(allocator: mem.Allocator, git_dir_path: []const u8, object_name: *const [20]u8, writer: anytype) !ObjectHeader {
    const hex_digest = try std.fmt.allocPrint(allocator, "{s}", .{ std.fmt.fmtSliceHexLower(object_name) });
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
    tag,
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

    var entries = Index.EntryList.init(allocator);

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
        .header = header,
        .entries = entries,
    };
    return index;
}

pub fn writeIndex(allocator: mem.Allocator, repo_path: []const u8, index: *const Index) !void {
    const index_path = try fs.path.join(allocator, &.{ repo_path, ".git", "index" });
    defer allocator.free(index_path);
    const index_file = try fs.cwd().createFile(index_path, .{ .read = true });
    defer index_file.close();

    const index_writer = index_file.writer();

    try index_writer.writeAll(&index.header.signature);
    try index_writer.writeIntBig(u32, index.header.version);
    try index_writer.writeIntBig(u32, @truncate(u32, index.entries.items.len));

    var entries: []*const Index.Entry = try allocator.alloc(*Index.Entry, index.entries.items.len);
    defer allocator.free(entries);

    for (index.entries.items) |*entry, idx| {
        entries[idx] = entry;
    }

    std.sort.sort(*const Index.Entry, entries, {}, sortIndexEntries);

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

pub fn sortIndexEntries(context: void, lhs: *const Index.Entry, rhs: *const Index.Entry) bool {
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
// TODO add extension support
pub const Index = struct {
    header: Header,
    entries: EntryList,

    pub fn init(allocator: mem.Allocator) !*Index {
        const index = try allocator.create(Index);
        index.* = .{
            .header = .{
                .signature = "DIRC".*,
                .version = 2,
                .entries = 0,
            },
            .entries = EntryList.init(allocator),
        };
        return index;
    }

    pub fn deinit(self: *const Index) void {
        for (self.entries.items) |entry| {
            entry.deinit(self.entries.allocator);
        }
        self.entries.deinit();
        self.entries.allocator.destroy(self);
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

        pub fn deinit(self: Entry, allocator: mem.Allocator) void {
            allocator.free(self.path);
        }

        pub fn format(self: Entry, comptime fmt: []const u8, options: std.fmt.FormatOptions, out_stream: anytype) !void {
            _ = fmt;
            _ = options;
            try out_stream.print("Index.Entry{{ mode: {o}, object_name: {s}, size: {d:4}, path: {s} }}",
                                 .{ @bitCast(u32, self.mode), std.fmt.fmtSliceHexLower(&self.object_name), self.file_size, self.path });
        }
    };

    pub const EntryList = std.ArrayList(Entry);

    pub const Mode = packed struct (u32) {
        unix_permissions: u9,
        unused: u3 = 0,
        object_type: EntryType,
        padding: u16 = 0,
    };

    pub const EntryType = enum(u4) {
        tree = 0o04,
        regular_file = 0o10,
        symbolic_link = 0o12,
        gitlink = 0o16,
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

pub fn readTree(allocator: mem.Allocator, git_dir_path: []const u8, object_name: *const [20]u8) !Tree {
    var entries = std.ArrayList(Tree.Entry).init(allocator);
    var object = std.ArrayList(u8).init(allocator);

    const object_type = try loadObject(allocator, git_dir_path, object_name, object.writer());
    if (object_type.@"type" != .tree) {
        return error.IncorrectObjectType;
    }

    var buffer = std.io.fixedBufferStream(object.items);
    const object_reader = buffer.reader();

    while (buffer.pos != object.items.len) {
        var mode_buffer: [16]u8 = undefined;
        const mode_text = try object_reader.readUntilDelimiter(&mode_buffer, ' ');
        const mode = @bitCast(Index.Mode, try std.fmt.parseInt(u32, mode_text, 8));
        const path = try object_reader.readUntilDelimiterAlloc(allocator, 0, std.math.maxInt(u32));
        const tree_object_name = try object_reader.readBytesNoEof(20);

        const entry = Tree.Entry{
            .mode = mode,
            .path = path,
            .object_name = tree_object_name,
        };

        try entries.append(entry);
    }

    return Tree{
        .allocator = allocator,
        .entries = try entries.toOwnedSlice(),
    };
}

pub fn writeTree(allocator: mem.Allocator, git_dir_path: []const u8, tree: Tree) ![20]u8 {
    var tree_data = std.ArrayList(u8).init(allocator);
    defer tree_data.deinit();
    var tree_writer = tree_data.writer();

    std.sort.sort(Tree.Entry, tree.entries, {}, sortTreeEntries);

    for (tree.entries) |entry| {
        try tree_writer.print("{o} {s}\x00", .{ @bitCast(u32, entry.mode), entry.path });
        try tree_writer.writeAll(&entry.object_name);
    }

    return saveObject(allocator, git_dir_path, tree_data.items, .tree);
}

fn sortTreeEntries(context: void, lhs: Tree.Entry, rhs: Tree.Entry) bool {
    _ = context;
    return mem.lessThan(u8, lhs.path, rhs.path);
}

pub const Tree = struct {
    allocator: mem.Allocator,
    entries: []Entry,

    pub fn deinit(self: *Tree) void {
        for (self.entries) |entry| {
            entry.deinit(self.allocator);
        }
    }

    pub const Entry = struct {
        mode: Index.Mode,
        path: []const u8,
        object_name: [20]u8,

        pub fn deinit(self: Entry, allocator: mem.Allocator) void {
            allocator.free(self.path);
        }
    };

    pub const EntryList = std.ArrayList(Tree.Entry);
};

pub fn indexToTree(allocator: mem.Allocator, repo_path: []const u8) ![20]u8 {
    const index = try readIndex(allocator, repo_path);
    defer index.deinit();

    var root = try NestedTree.init(allocator, "");

    for (index.entries.items) |index_entry| {
        var entry = Tree.Entry{
            .mode = index_entry.mode,
            .path = try allocator.dupe(u8, fs.path.basename(index_entry.path)),
            .object_name = index_entry.object_name,
        };

        const dir = fs.path.dirname(index_entry.path);

        if (dir == null) {
            try root.entries.append(entry);
            continue;
        }

        const valid_dir = dir.?;
        var dir_iter = mem.split(u8, valid_dir, fs.path.sep_str);
        var cur_tree = &root;
        iter: while (dir_iter.next()) |sub_dir| {
            for (cur_tree.subtrees.items) |*subtree| {
                if (mem.eql(u8, subtree.path, sub_dir)) {
                    cur_tree = subtree;
                    continue :iter;
                }
            }
            var nested_tree = try NestedTree.init(allocator, sub_dir);
            try cur_tree.subtrees.append(nested_tree);
            cur_tree = &cur_tree.subtrees.items[cur_tree.subtrees.items.len-1];
        }
        try cur_tree.entries.append(entry);
    }

    const git_dir_path = try fs.path.join(allocator, &.{ repo_path, ".git" });
    defer allocator.free(git_dir_path);

    const root_tree = try root.toTree(git_dir_path);
    return writeTree(allocator, git_dir_path, root_tree);
}


pub const NestedTree = struct {
    allocator: mem.Allocator,
    entries: Tree.EntryList,
    subtrees: NestedTreeList,
    path: []const u8,

    pub fn init(allocator: mem.Allocator, path: []const u8) !NestedTree {
        return .{
            .allocator = allocator,
            .entries = Tree.EntryList.init(allocator),
            .subtrees = NestedTreeList.init(allocator),
            .path = try allocator.dupe(u8, path),
        };
    }

    pub fn deinit(self: NestedTree) void {
        self.allocator.free(self.path);
        for (self.entries.items) |entry| {
            entry.deinit();
        }
        self.entries.deinit();
        for (self.subtrees.items) |subtree| {
            subtree.deinit();
        }
        self.subtrees.deinit();
    }

    pub fn toTree(self: *NestedTree, git_dir_path: []const u8) !Tree {
        if (self.subtrees.items.len == 0) {
            return .{
                .allocator = self.allocator,
                .entries = try self.entries.toOwnedSlice(),
            };
        }

        for (self.subtrees.items) |*subtree| {
            var tree = try subtree.toTree(git_dir_path);
            const object_name = try writeTree(self.allocator, git_dir_path, tree);
            var entry = Tree.Entry{
                .mode = Index.Mode{
                    .unix_permissions = 0,
                    .object_type = .tree,
                },
                .path = subtree.path,
                .object_name = object_name,
            };
            try self.entries.append(entry);
        }

        self.subtrees.clearAndFree();

        return .{
            .allocator = self.allocator,
            .entries = try self.entries.toOwnedSlice(),
        };
    }
};

pub const NestedTreeList = std.ArrayList(NestedTree);


pub fn addFileToIndex(allocator: mem.Allocator, repo_path: []const u8, file_path: []const u8) !void {
    var index = readIndex(allocator, repo_path) catch |err| switch (err) {
        error.FileNotFound => try Index.init(allocator),
        else => return err,
    };
    defer index.deinit();

    const entry = try fileToIndexEntry(allocator, repo_path, file_path);
    errdefer entry.deinit(allocator);

    var replaced = false;

    for (index.entries.items) |*existing_entry| {
        if (mem.eql(u8, existing_entry.path, entry.path)) {
            std.debug.print("Replacing index entry at path {s}\n", .{ entry.path });
            // Replace entry instead of removing old and adding new separately
            existing_entry.deinit(allocator);
            existing_entry.* = entry;
            replaced = true;
            break;
        }
    }

    if (!replaced) {
        try index.entries.append(entry);
        index.header.entries += 1;
    }

    try writeIndex(allocator, repo_path, index);
}

pub fn fileToIndexEntry(allocator: mem.Allocator, repo_path: []const u8, file_path: []const u8) !Index.Entry {
    const file = try fs.cwd().openFile(file_path, .{});
    const stat = try os.fstat(file.handle);
    const absolute_repo_path = try fs.cwd().realpathAlloc(allocator, repo_path);
    defer allocator.free(absolute_repo_path);
    const absolute_file_path = try fs.cwd().realpathAlloc(allocator, file_path);
    defer allocator.free(absolute_file_path);
    const repo_relative_path = try fs.path.relative(allocator, absolute_repo_path, absolute_file_path);

    const data = try file.readToEndAlloc(allocator, std.math.maxInt(u32));
    defer allocator.free(data);

    const name_len = blk: {
        if (repo_relative_path.len > 0xFFF) {
            break :blk @as(u12, 0xFFF);
        } else {
            break :blk @truncate(u12, repo_relative_path.len);
        }
    };

    const git_dir_path = try repoToGitDir(allocator, repo_path);
    defer allocator.free(git_dir_path);

    const object_name = try saveObject(allocator, git_dir_path, data, .blob);

    const entry = Index.Entry{
        .ctime_s = @intCast(u32, stat.ctime().tv_sec),
        .ctime_n = @intCast(u32, stat.ctime().tv_nsec),
        .mtime_s = @intCast(u32, stat.mtime().tv_sec),
        .mtime_n = @intCast(u32, stat.mtime().tv_nsec),
        .dev = @intCast(u32, stat.dev),
        .ino = @intCast(u32, stat.ino),
        .mode = @bitCast(Index.Mode, @as(u32, stat.mode)),
        .uid = stat.uid,
        .gid = stat.gid,
        .file_size = @intCast(u32, stat.size),
        .object_name = object_name,
        .flags = .{
            .name_length = name_len,
            .stage = 0,
            .extended = false,
            .assume_valid = false,
        },
        .extended_flags = null,
        .path = repo_relative_path,
    };

    return entry;
}

pub fn repoToGitDir(allocator: mem.Allocator, repo_path: []const u8) ![]const u8 {
    return try fs.path.join(allocator, &.{ repo_path, ".git" });
}

pub fn writeCommit(allocator: mem.Allocator, repo_path: []const u8, commit: Commit) ![20]u8 {
    var commit_data = std.ArrayList(u8).init(allocator);
    defer commit_data.deinit();

    const writer = commit_data.writer();

    try writer.print("tree {s}\n", .{ std.fmt.fmtSliceHexLower(&commit.tree) });
    for (commit.parents.items) |parent| {
        try writer.print("parent {s}\n", .{ std.fmt.fmtSliceHexLower(parent) });
    }
    const author = commit.author;
    try writer.print("author {}\n", .{ author });
    const committer = commit.comitter;
    try writer.print("committer {}\n", .{ committer });

    try writer.print("\n{s}\n", .{ commit.message });

    const git_dir_path = repoToGitDir(allocator, repo_path);
    defer allocator.free(git_dir_path);

    return saveObject(allocator, git_dir_path, commit_data.items, .commit);
}

pub const Commit = struct {
    allocator: mem.Allocator,
    tree: [20]u8,
    parents: ObjectNameList,
    author: Committer,
    committer: Committer,
    message: []const u8,

    pub const Committer = struct {
        name: []const u8,
        email: []const u8,
        time: i64,
        timezone: i16,

        pub fn format(self: Committer, comptime fmt: []const u8, options: std.fmt.FormatOptions, out_stream: anytype) !void {
            _ = fmt;
            _ = options;
            try out_stream.print("{s} <{s}> {d} {d}", .{ self.name, self.email, self.time, self.timezone });
        }
    };
};

pub const ObjectNameList = std.ArrayList([20]u8);

test "ref all" {
    std.testing.refAllDecls(@This());
}
