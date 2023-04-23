const std = @import("std");
const os = std.os;
const mem = std.mem;
const fs = std.fs;
const zlib_writer = @import("zlib_writer.zig");
const zlibStreamWriter = zlib_writer.zlibStreamWriter;
const ZlibStreamWriter = zlib_writer.ZlibStreamWriter;

pub fn main() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{ .stack_trace_frames = 12 }){};
    var allocator = gpa.allocator();
    defer _ = gpa.deinit();

    var args = std.process.args();
    _ = args.next();

    const subcommand = args.next() orelse {
        std.debug.print(
            \\No subcommand specified.
            \\Available subcommands:
            \\add
            \\branch
            \\branch-create
            \\commit
            \\index
            \\init
            \\log
            \\read-commit
            \\read-ref
            \\read-tag
            \\read-tree
            \\refs
            \\status
            \\
            , .{});
        return;
    };

    if (mem.eql(u8, subcommand, "index")) {
        const repo_root = try findRepoRoot(allocator);
        defer allocator.free(repo_root);

        std.debug.print("Repo root: {s}\n", .{ repo_root });
        const index = readIndex(allocator, repo_root) catch |err| switch (err) {
            error.FileNotFound => {
                std.debug.print("No index\n", .{});
                return;
            },
            else => return err,
        };
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

        var index = readIndex(allocator, repo_path) catch |err| switch (err) {
            error.FileNotFound => try Index.init(allocator),
            else => return err,
        };
        defer index.deinit();

        const stat = try fs.cwd().statFile(file_path);
        switch (stat.kind) {
            .Directory => try addFilesToIndex(allocator, repo_path, index, file_path),
            .SymLink, .File, => try addFileToIndex(allocator, repo_path, index, file_path),
            else => |tag| std.debug.print("Cannot add file of type {s} to index\n", .{ @tagName(tag) }),
        }

        try writeIndex(allocator, repo_path, index);


    } else if (mem.eql(u8, subcommand, "commit")) {
        const repo_root = try findRepoRoot(allocator);
        defer allocator.free(repo_root);

        const git_dir_path = try repoToGitDir(allocator, repo_root);
        defer allocator.free(git_dir_path);

        const tree = try indexToTree(allocator, repo_root);
        const committer = Commit.Committer{
            .name = "Gaba Goul",
            .email = "gaba@cool.ca",
            .time = std.time.timestamp(),
            .timezone = 1,
        };
        var parents = ObjectNameList.init(allocator);
        defer parents.deinit();

        const head_ref = try resolveRef(allocator, git_dir_path, "HEAD");
        if (head_ref) |valid_ref| {
            try parents.append(valid_ref);
        }

        var commit = Commit{
            .allocator = allocator,
            .tree = tree,
            .parents = parents,
            .author = committer,
            .committer = committer,
            .message = "Second commit test!",
        };

        const object_name = try writeCommit(allocator, git_dir_path, commit);

        if (try currentRef(allocator, git_dir_path)) |current_ref| {
            defer allocator.free(current_ref);
            std.debug.print("Commit {s} to {s}\n", .{ std.fmt.fmtSliceHexLower(&object_name), current_ref });

            try updateRef(allocator, git_dir_path, current_ref, .{ .object_name = object_name });
        } else {
            std.debug.print("Warning: In a detached HEAD state\n", .{});
            std.debug.print("Commit {s}\n", .{ std.fmt.fmtSliceHexLower(&object_name) });

            try updateRef(allocator, git_dir_path, "HEAD", .{ .object_name = object_name });
        }

    } else if (mem.eql(u8, subcommand, "branch")) {
        const repo_path = try findRepoRoot(allocator);
        defer allocator.free(repo_path);

        const git_dir_path = try repoToGitDir(allocator, repo_path);
        defer allocator.free(git_dir_path);

        const current_ref = try currentHeadRef(allocator, git_dir_path);

        defer if (current_ref) |valid_ref| allocator.free(valid_ref);

        var refs = try listHeadRefs(allocator, git_dir_path);
        defer refs.deinit();

        std.sort.sort([]const u8, refs.refs, {}, sortStrings);

        for (refs.refs) |ref| {
            const indicator: u8 = blk: {
                if (current_ref) |valid_ref| {
                    break :blk if (mem.eql(u8, valid_ref, ref)) '*' else ' ';
                } else break :blk ' ';
            };
            std.debug.print("{c} {s}\n", .{ indicator, ref });
        }

    } else if (mem.eql(u8, subcommand, "branch-create")) {
        const new_branch_name = args.next() orelse {
            std.debug.print("No branch name specified\n", .{});
            return;
        };

        const repo_path = try findRepoRoot(allocator);
        defer allocator.free(repo_path);

        const git_dir_path = try repoToGitDir(allocator, repo_path);
        defer allocator.free(git_dir_path);

        const current_commit = try resolveRef(allocator, git_dir_path, "HEAD");
        if (current_commit) |valid_commit_object_name| {
            try updateRef(allocator, git_dir_path, new_branch_name, .{ .object_name = valid_commit_object_name });
        }
        try updateRef(allocator, git_dir_path, "HEAD", .{ .ref = new_branch_name });


    } else if (mem.eql(u8, subcommand, "refs")) {
        const repo_path = try findRepoRoot(allocator);
        defer allocator.free(repo_path);

        const git_dir_path = try repoToGitDir(allocator, repo_path);
        defer allocator.free(git_dir_path);

        const refs = try listRefs(allocator, git_dir_path);
        defer refs.deinit();

        for (refs.refs) |ref| {
            std.debug.print("{s}\n", .{ ref });
        }

    } else if (mem.eql(u8, subcommand, "read-tree")) {
        const tree_hash_digest = args.next() orelse {
            std.debug.print("No tree object name specified\n", .{});
            return;
        };

        const repo_path = try findRepoRoot(allocator);
        defer allocator.free(repo_path);

        const git_dir_path = try repoToGitDir(allocator, repo_path);
        defer allocator.free(git_dir_path);

        var tree_name_buffer: [20]u8 = undefined;
        const tree_object_name = try std.fmt.hexToBytes(&tree_name_buffer, tree_hash_digest);
        _ = tree_object_name;

        var walker = try walkTree(allocator, git_dir_path, tree_name_buffer);
        defer walker.deinit();

        while (try walker.next()) |entry| {
            std.debug.print("{}\n", .{ entry });
        }

    } else if (mem.eql(u8, subcommand, "read-commit")) {
        const commit_hash_digest = args.next() orelse {
            std.debug.print("No commit object hash specified\n", .{});
            return;
        };

        const repo_path = try findRepoRoot(allocator);
        defer allocator.free(repo_path);

        const git_dir_path = try repoToGitDir(allocator, repo_path);
        defer allocator.free(git_dir_path);

        const commit_object_name = try hexDigestToObjectName(commit_hash_digest);
        const commit = try readCommit(allocator, git_dir_path, commit_object_name);
        defer commit.deinit();

        std.debug.print("{any}\n", .{ commit });

    } else if (mem.eql(u8, subcommand, "root")) {
        const repo_path = try findRepoRoot(allocator);
        defer allocator.free(repo_path);

        std.debug.print("{s}\n", .{ repo_path });

    } else if (mem.eql(u8, subcommand, "read-ref")) {
        const ref_name = args.next();

        const repo_path = try findRepoRoot(allocator);
        defer allocator.free(repo_path);

        const git_dir_path = try repoToGitDir(allocator, repo_path);
        defer allocator.free(git_dir_path);

        if (ref_name) |valid_ref_name| {
            const ref = try readRef(allocator, git_dir_path, valid_ref_name) orelse return;
            defer ref.deinit(allocator);

            std.debug.print("{}\n", .{ ref });
        } else {
            const ref_list = try listRefs(allocator, git_dir_path);
            defer ref_list.deinit();

            for (ref_list.refs) |ref_path| {
                const ref = try readRef(allocator, git_dir_path, ref_path);
                defer ref.?.deinit(allocator);

                std.debug.print("{s}: {}\n", .{ ref_path, ref.? });
            }
        }
    } else if (mem.eql(u8, subcommand, "read-tag")) {
        const tag_name = args.next() orelse {
            std.debug.print("No tag specified\n", .{});
            return;
        };

        const repo_path = try findRepoRoot(allocator);
        defer allocator.free(repo_path);

        const git_dir_path = try repoToGitDir(allocator, repo_path);
        defer allocator.free(git_dir_path);

        const tag_object_name = try hexDigestToObjectName(tag_name);

        const tag = try readTag(allocator, git_dir_path, tag_object_name);
        defer tag.deinit();

        std.debug.print("{}\n", .{ tag });
    } else if (mem.eql(u8, subcommand, "log")) {
        const repo_path = try findRepoRoot(allocator);
        defer allocator.free(repo_path);

        const git_dir_path = try repoToGitDir(allocator, repo_path);
        defer allocator.free(git_dir_path);

        const commit_object_name = try resolveHead(allocator, git_dir_path) orelse return;

        var commit: ?*Commit = null;
        commit = try readCommit(allocator, git_dir_path, commit_object_name);

        while (commit) |valid_commit| {
            const old_commit = valid_commit;
            defer old_commit.deinit();

            std.debug.print("{}\n", .{valid_commit});
            if (valid_commit.parents.items.len >= 1) {
                // HACK We only look at the first parent, we should
                // look at all (for merges, etc.)
                commit = try readCommit(allocator, git_dir_path, valid_commit.parents.items[0]);
            } else {
                commit = null;
            }
        }

    } else if (mem.eql(u8, subcommand, "status")) {
        // TODO Give more useful status information

        const repo_path = try findRepoRoot(allocator);
        defer allocator.free(repo_path);

        const git_dir_path = try repoToGitDir(allocator, repo_path);
        defer allocator.free(git_dir_path);

        const current_ref = try currentHead(allocator, git_dir_path);
        if (current_ref) |valid_ref| {
            defer valid_ref.deinit(allocator);

            switch (valid_ref) {
                .ref => |ref| std.debug.print("On branch {s}\n", .{ std.mem.trimLeft(u8, ref, "refs/heads/") }),
                .object_name => |object_name| std.debug.print("Detached HEAD {s}\n", .{ std.fmt.fmtSliceHexLower(&object_name) }),
            }
        }
    }
}

/// Initialize a normal git repo
pub fn initialize(allocator: mem.Allocator, repo_path: []const u8) !void {
    const bare_path = try fs.path.join(allocator, &.{ repo_path, ".git" });
    defer allocator.free(bare_path);

    try fs.cwd().makePath(repo_path);
    try initializeBare(allocator, bare_path);
}

/// Initialize a bare git repo (no index or working directory)
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

/// Hashes data and returns its object name
pub fn hashObject(data: []const u8, obj_type: ObjectType, digest: *[20]u8) void {
    var hash = std.crypto.hash.Sha1.init(.{});
    const writer = hash.writer();
    try writer.print("{s} {d}\x00", .{ @tagName(obj_type), data.len });
    try writer.writeAll(data);
    hash.final(digest);
}

// TODO Maybe rewrite to use a reader interface instead of a data slice
/// Writes data to an object and returns its object name
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

/// Returns a reader for an object's data
pub fn objectReader(allocator: mem.Allocator, git_dir_path: []const u8, object_name: [20]u8) !ObjectReader {
    return ObjectReader.init(allocator, git_dir_path, object_name);
}

pub const ObjectReader = struct {
    decompressor: Decompressor,
    file: fs.File,
    header: ObjectHeader,

    pub const Decompressor = std.compress.zlib.ZlibStream(fs.File.Reader);
    pub const Reader = Decompressor.Reader;
    const Self = @This();

    pub fn reader(self: *Self) Reader {
        return self.decompressor.reader();
    }

    pub fn init(allocator: mem.Allocator, git_dir_path: []const u8, object_name: [20]u8) !ObjectReader {
        var hex_buffer: [40]u8 = undefined;
        const hex_digest = try std.fmt.bufPrint(&hex_buffer, "{s}", .{ std.fmt.fmtSliceHexLower(&object_name) });

        const path = try fs.path.join(allocator, &.{ git_dir_path, "objects", hex_digest[0..2], hex_digest[2..] });
        defer allocator.free(path);

        const file = try fs.cwd().openFile(path, .{});

        var decompressor = try std.compress.zlib.zlibStream(allocator, file.reader());
        const decompressor_reader = decompressor.reader();

        const header = try decompressor_reader.readUntilDelimiterAlloc(allocator, 0, 1024);
        defer allocator.free(header);

        var header_iter = mem.split(u8, header, " ");
        const object_type = std.meta.stringToEnum(ObjectType, header_iter.first()) orelse return error.InvalidObjectType;
        const size = blk: {
            const s = header_iter.next() orelse return error.InvalidObjectSize;
            const n = try std.fmt.parseInt(u32, s, 10);
            break :blk n;
        };

        const object_header = ObjectHeader{
            .@"type" = object_type,
            .size = size,
        };

        return .{
            .decompressor = decompressor,
            .file = file,
            .header = object_header,
        };
    }

    pub fn deinit(self: *Self) void {
        self.decompressor.deinit();
        self.file.close();
    }
};

/// Returns the data for an object
pub fn loadObject(allocator: mem.Allocator, git_dir_path: []const u8, object_name: [20]u8, writer: anytype) !ObjectHeader {
    var object_reader = try objectReader(allocator, git_dir_path, object_name);
    defer object_reader.deinit();

    const reader = object_reader.reader();

    var fifo = std.fifo.LinearFifo(u8, .{ .Static = 4096 }).init();
    try fifo.pump(reader, writer);

    return object_reader.header;
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

/// Returns a repo's current index
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

        const path = try index_reader.readUntilDelimiterAlloc(allocator, 0, fs.MAX_PATH_BYTES);

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

/// Writes the index to the repo's git folder
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

    for (index.entries.items, 0..) |*entry, idx| {
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
            try out_stream.print("Index.Entry{{ mode: {o}, object_name: {s}, size: {d:5}, path: {s} }}",
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

pub fn readTree(allocator: mem.Allocator, git_dir_path: []const u8, object_name: [20]u8) !Tree {
    var entries = std.ArrayList(Tree.Entry).init(allocator);
    var object = std.ArrayList(u8).init(allocator);
    defer object.deinit();

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
        const path = try object_reader.readUntilDelimiterAlloc(allocator, 0, fs.MAX_PATH_BYTES);
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

/// Writes a tree to an object and returns the name
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

    pub fn deinit(self: *const Tree) void {
        for (self.entries) |entry| {
            entry.deinit(self.allocator);
        }
        self.allocator.free(self.entries);
    }

    pub const Entry = struct {
        mode: Index.Mode,
        path: []const u8,
        object_name: [20]u8,

        pub fn deinit(self: Entry, allocator: mem.Allocator) void {
            allocator.free(self.path);
        }

        pub fn format(self: Entry, comptime fmt: []const u8, options: std.fmt.FormatOptions, out_stream: anytype) !void {
            _ = options;
            _ = fmt;

            try out_stream.print("Tree.Entry{{ mode: {o: >6}, object_name: {s}, path: {s} }}",
                                 .{ @bitCast(u32, self.mode), std.fmt.fmtSliceHexLower(&self.object_name), self.path });
        }
    };

    pub const EntryList = std.ArrayList(Tree.Entry);
};

/// Transforms an Index into a tree object and stores it. Returns the
/// object's name
pub fn indexToTree(child_allocator: mem.Allocator, repo_path: []const u8) ![20]u8 {
    var arena = std.heap.ArenaAllocator.init(child_allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    const index = try readIndex(allocator, repo_path);

    var root = try NestedTree.init(allocator, "");

    for (index.entries.items) |index_entry| {
        var tree_entry = Tree.Entry{
            .mode = index_entry.mode,
            .path = fs.path.basename(index_entry.path),
            .object_name = index_entry.object_name,
        };

        const dir = fs.path.dirname(index_entry.path);

        if (dir == null) {
            try root.entries.append(tree_entry);
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
        try cur_tree.entries.append(tree_entry);
    }

    const git_dir_path = try fs.path.join(allocator, &.{ repo_path, ".git" });

    return root.toTree(git_dir_path);
}

/// Represents a nested git tree (trees are flat with references to
/// other trees)
const NestedTree = struct {
    allocator: mem.Allocator,
    entries: Tree.EntryList,
    subtrees: NestedTreeList,
    path: []const u8,

    pub fn init(allocator: mem.Allocator, path: []const u8) !NestedTree {
        return .{
            .allocator = allocator,
            .entries = Tree.EntryList.init(allocator),
            .subtrees = NestedTreeList.init(allocator),
            .path = path,
        };
    }

    pub fn toTree(self: *NestedTree, git_dir_path: []const u8) ![20]u8 {

        if (self.subtrees.items.len == 0) {
            const tree = Tree{
                .allocator = self.allocator,
                .entries = self.entries.items,
            };
            return writeTree(self.allocator, git_dir_path, tree);
        }

        for (self.subtrees.items) |*subtree| {
            var child_object_name = try subtree.toTree(git_dir_path);

            var entry = Tree.Entry{
                .mode = Index.Mode{
                    .unix_permissions = 0,
                    .object_type = .tree,
                },
                .path = subtree.path,
                .object_name = child_object_name,
            };
            try self.entries.append(entry);
        }

        const tree = Tree{
            .allocator = self.allocator,
            .entries = self.entries.items,
        };

        return writeTree(self.allocator, git_dir_path, tree);
    }
};

const NestedTreeList = std.ArrayList(NestedTree);

/// Recursively add files to an index
pub fn addFilesToIndex(allocator: mem.Allocator, repo_path: []const u8, index: *Index, dir_path: []const u8) !void {
    var dir_iterable = try fs.cwd().openIterableDir(dir_path, .{});
    defer dir_iterable.close();

    var walker = try dir_iterable.walk(allocator);
    defer walker.deinit();

    while (try walker.next()) |walker_entry| {
        switch (walker_entry.kind) {
            .SymLink, .File => {
                const joined_path = try fs.path.join(allocator, &.{ dir_path, walker_entry.path });
                defer allocator.free(joined_path);
                try addFileToIndex(allocator, repo_path, index, joined_path);
            },
            .Directory => continue,
            else => |tag| std.debug.print("Cannot add type {s} to index\n", .{ @tagName(tag) }),
        }
    }
}

/// Add the file at the path to an index
pub fn addFileToIndex(allocator: mem.Allocator, repo_path: []const u8, index: *Index, file_path: []const u8) !void {
    const entry = try fileToIndexEntry(allocator, repo_path, file_path);
    errdefer entry.deinit(allocator);

    var path_iter = mem.split(u8, file_path, fs.path.sep_str);
    while (path_iter.next()) |dir| {
        // Don't add .git files to the index
        if (mem.eql(u8, dir, ".git") or mem.endsWith(u8, dir, ".git")) {
            entry.deinit(allocator);
            return;
        }
    }

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
}

/// Reads file's details and returns a matching Index.Entry
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

/// Returns a repo's .git directory path
pub fn repoToGitDir(allocator: mem.Allocator, repo_path: []const u8) ![]const u8 {
    return try fs.path.join(allocator, &.{ repo_path, ".git" });
}

/// Writes a commit object and returns its name
pub fn writeCommit(allocator: mem.Allocator, git_dir_path: []const u8, commit: Commit) ![20]u8 {
    var commit_data = std.ArrayList(u8).init(allocator);
    defer commit_data.deinit();

    const writer = commit_data.writer();

    try writer.print("tree {s}\n", .{ std.fmt.fmtSliceHexLower(&commit.tree) });
    for (commit.parents.items) |parent| {
        try writer.print("parent {s}\n", .{ std.fmt.fmtSliceHexLower(&parent) });
    }
    const author = commit.author;
    try writer.print("author {}\n", .{ author });
    const committer = commit.committer;
    try writer.print("committer {}\n", .{ committer });

    try writer.print("\n{s}\n", .{ commit.message });

    return saveObject(allocator, git_dir_path, commit_data.items, .commit);
}

/// Returns a Commit with a certain object name
pub fn readCommit(allocator: mem.Allocator, git_dir_path: []const u8, commit_object_name: [20]u8) !*Commit {
    var commit_data = std.ArrayList(u8).init(allocator);
    defer commit_data.deinit();

    const commit_object_header = try loadObject(allocator, git_dir_path, commit_object_name, commit_data.writer());
    if (commit_object_header.@"type" != .commit) {
        return error.InvalidObjectType;
    }

    var tree: ?[20]u8 = null;
    var parents = ObjectNameList.init(allocator);
    var author: ?Commit.Committer = null;
    var committer: ?Commit.Committer = null;
    var pgp_signature: ?std.ArrayList(u8) = null;

    errdefer {
        parents.deinit();
        if (author) |valid_author| {
            valid_author.deinit(allocator);
        }
        if (committer) |valid_committer| {
            valid_committer.deinit(allocator);
        }
        if (pgp_signature) |sig| {
            sig.deinit();
        }
    }

    var lines = mem.split(u8, commit_data.items, "\n");
    var in_pgp = false;

    while (lines.next()) |line| {
        if (mem.eql(u8, line, "")) {
            break;
        }
        if (in_pgp and mem.indexOf(u8, line, "-----END PGP SIGNATURE-----") != null) {
            try pgp_signature.?.appendSlice(line);
            in_pgp = false;
            _ = lines.next(); // PGP signatures have a trailing empty line
            continue;
        }
        if (in_pgp) {
            try pgp_signature.?.appendSlice(line);
            try pgp_signature.?.append('\n');
            continue;
        }
        var words = mem.tokenize(u8, line, " ");
        const key = words.next() orelse {
            std.debug.print("commit data:\n{s}\n", .{ commit_data.items });
            return error.MissingCommitPropertyKey;
        };
        if (mem.eql(u8, key, "tree")) {
            const hex = words.next() orelse return error.InvalidTreeObjectName;
            tree = try hexDigestToObjectName(hex);
        } else if (mem.eql(u8, key, "parent")) {
            const hex = words.next() orelse return error.InvalidParentObjectName;
            try parents.append(try hexDigestToObjectName(hex));
        } else if (mem.eql(u8, key, "author")) {
            author = try Commit.Committer.parse(allocator, words.rest());
        } else if (mem.eql(u8, key, "committer")) {
            committer = try Commit.Committer.parse(allocator, words.rest());
        } else if (mem.eql(u8, key, "gpgsig")) {
            in_pgp = true;
            pgp_signature = std.ArrayList(u8).init(allocator);
            try pgp_signature.?.appendSlice(words.rest());
        }
    }

    const message = try allocator.dupe(u8, lines.rest());
    errdefer allocator.free(message);
    const commit = try allocator.create(Commit);
    errdefer allocator.destroy(commit);

    commit.* = Commit{
        .allocator = allocator,
        .tree = tree orelse return error.MissingTree,
        .parents = parents,
        .author = author orelse return error.MissingAuthor,
        .committer = committer orelse return error.MissingCommitter,
        .message = message,
        .pgp_signature = if (pgp_signature) |*sig| try sig.toOwnedSlice() else null,
    };

    return commit;
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

pub const Commit = struct {
    allocator: mem.Allocator,
    tree: [20]u8,
    parents: ObjectNameList,
    author: Committer,
    committer: Committer,
    message: []const u8,
    pgp_signature: ?[]const u8 = null,

    pub fn deinit(self: *const Commit) void {
        self.parents.deinit();
        self.author.deinit(self.allocator);
        self.committer.deinit(self.allocator);
        self.allocator.free(self.message);
        if (self.pgp_signature) |sig| {
            self.allocator.free(sig);
        }
        self.allocator.destroy(self);
    }

    pub fn format(self: Commit, comptime fmt: []const u8, options: std.fmt.FormatOptions, out_stream: anytype) !void {
        _ = fmt;
        _ = options;

        try out_stream.print("Commit{{\n", .{});
        try out_stream.print("  Tree: {s}\n", .{ std.fmt.fmtSliceHexLower(&self.tree) });
        for (self.parents.items) |parent| {
            try out_stream.print("  Parent: {s}\n", .{ std.fmt.fmtSliceHexLower(&parent) });
        }
        try out_stream.print("  Author: {}\n", .{ self.author });
        try out_stream.print("  Committer: {}\n", .{ self.committer });
        try out_stream.print("  Message: {s}\n", .{ self.message });
        if (self.pgp_signature) |sig| {
            try out_stream.print("  PGP Signature:\n{s}\n", .{ sig });
        }
        try out_stream.print("}}\n", .{});
    }

    pub const Committer = struct {
        name: []const u8,
        email: []const u8,
        time: i64,
        timezone: i16,

        pub fn deinit(self: Committer, allocator: mem.Allocator) void {
            allocator.free(self.name);
            allocator.free(self.email);
        }

        pub fn parse(allocator: mem.Allocator, line: []const u8) !Committer {
            var email_split = mem.tokenize(u8, line, "<>");
            const name = mem.trimRight(u8, email_split.next() orelse return error.InvalidCommitter, " ");
            const email = email_split.next() orelse return error.InvalidCommitter;
            var time_split = mem.tokenize(u8, email_split.rest(), " ");
            const unix_time = time_split.next() orelse return error.InvalidCommitter;
            const timezone = time_split.next() orelse return error.InvalidCommitter;

            return .{
                .name = try allocator.dupe(u8, name),
                .email = try allocator.dupe(u8, email),
                .time = try std.fmt.parseInt(i64, unix_time, 10),
                .timezone = try std.fmt.parseInt(i16, timezone, 10),
            };
        }

        pub fn format(self: Committer, comptime fmt: []const u8, options: std.fmt.FormatOptions, out_stream: anytype) !void {
            _ = fmt;
            _ = options;
            const sign: u8 = if (self.timezone > 0) '+' else '-';
            const timezone = @intCast(u16, std.math.absInt(self.timezone) catch 0);
            try out_stream.print("{s} <{s}> {d} {c}{d:0>4}", .{ self.name, self.email, self.time, sign, timezone });
        }
    };
};

pub const ObjectNameList = std.ArrayList([20]u8);

/// Recursively resolves the HEAD until an object name is found.
pub fn resolveHead(allocator: mem.Allocator, git_dir_path: []const u8) !?[20]u8 {
    return try resolveRef(allocator, git_dir_path, "HEAD");
}

/// Recursively resolves refs until an object name is found.
pub fn resolveRef(allocator: mem.Allocator, git_dir_path: []const u8,  ref: []const u8) !?[20]u8 {
    const current_ref = try readRef(allocator, git_dir_path, ref) orelse return null;

    switch (current_ref) {
        // TODO avoid infinite recursion on cyclical references
        .ref => |ref_name| {
            defer current_ref.deinit(allocator);
            return try resolveRef(allocator, git_dir_path, ref_name);
        },
        .object_name => |object_name| return object_name,
    }
}

/// Returns the filesystem path to a ref
/// Caller responsible for memory
pub fn refToPath(allocator: mem.Allocator, git_dir_path: []const u8, ref: []const u8) ![]const u8 {
    const full_ref = try expandRef(allocator, ref);
    defer allocator.free(full_ref);

    return fs.path.join(allocator, &.{ git_dir_path, full_ref });
}

/// Returns the full expanded name of a ref
/// Caller responsible for memory
pub fn expandRef(allocator: mem.Allocator, ref: []const u8) ![]const u8 {
    if (mem.eql(u8, ref, "HEAD") or mem.startsWith(u8, ref, "refs/")) {
        return allocator.dupe(u8, ref);
    } else if (mem.indexOf(u8, ref, "/") == null) {
        return fs.path.join(allocator, &.{ "refs/heads", ref });
    }
    return error.InvalidRef;
}

/// Updates the target for a ref
pub fn updateRef(allocator: mem.Allocator, git_dir_path: []const u8, ref: []const u8, target: Ref) !void {
    const full_path = try refToPath(allocator, git_dir_path, ref);
    defer allocator.free(full_path);

    const file = try fs.cwd().createFile(full_path, .{});
    defer file.close();

    switch (target) {
        .ref => |ref_name| {
            const full_ref = try expandRef(allocator, ref_name);
            defer allocator.free(full_ref);

            try file.writer().print("ref: {s}\n", .{ full_ref });
        },
        .object_name => |object_name| try file.writer().print("{s}\n", .{ std.fmt.fmtSliceHexLower(&object_name) }),
    }
}

/// Represents a git ref. Either an object name or a pointer to
/// another ref
pub const Ref = union(enum) {
    ref: []const u8,
    object_name: [20]u8,

    pub fn deinit(self: Ref, allocator: mem.Allocator) void {
        switch (self) {
            .ref => allocator.free(self.ref),
            else => {},
        }
    }

    pub fn format(self: Ref, comptime fmt: []const u8, options: std.fmt.FormatOptions, out_stream: anytype) !void {
        _ = fmt;
        _ = options;

        switch (self) {
            .ref => |ref| try out_stream.print("{s}", .{ ref }),
            .object_name => |object_name| try out_stream.print("{s}", .{ std.fmt.fmtSliceHexLower(&object_name) }),
        }
    }
};

/// Returns the target of a ref
pub fn readRef(allocator: mem.Allocator, git_dir_path: []const u8, ref: []const u8) !?Ref {
    const ref_path = try refToPath(allocator, git_dir_path, ref);
    defer allocator.free(ref_path);

    const file = fs.cwd().openFile(ref_path, .{}) catch |err| switch (err) {
        error.FileNotFound => return null,
        else => return err,
    };
    defer file.close();

    const data = try file.reader().readUntilDelimiterAlloc(allocator, '\n', 4096);
    defer allocator.free(data);

    if (mem.startsWith(u8, data, "ref: ")) {
        return .{ .ref = try allocator.dupe(u8, data[5..]) };
    } else {
        return .{ .object_name = try hexDigestToObjectName(data[0..40]) };
    }
}

/// Returns the current HEAD Ref
pub fn currentHead(allocator: mem.Allocator, git_dir_path: []const u8) !?Ref {
    return readRef(allocator, git_dir_path, "HEAD");
}

/// Returns the full current HEAD ref, only if it's the name of another
/// ref. Retruns null if it's anything else
/// Caller responsible for memory.
pub fn currentRef(allocator: mem.Allocator, git_dir_path: []const u8) !?[]const u8 {
    const current_ref = try readRef(allocator, git_dir_path, "HEAD") orelse return null;
    return switch (current_ref) {
        .ref => |ref| ref,
        .object_name => null,
    };
}

/// Returns the name of the current head ref (branch name)
pub fn currentHeadRef(allocator: mem.Allocator, git_dir_path: []const u8) !?[]const u8 {
    const current_ref = try currentRef(allocator, git_dir_path) orelse return null;

    defer allocator.free(current_ref);

    const current_head_ref = std.mem.trimLeft(u8, current_ref, "refs/heads/");
    return try allocator.dupe(u8, current_head_ref);
}

/// Returns a list of all head ref names (branch names)
pub fn listHeadRefs(allocator: mem.Allocator, git_dir_path: []const u8) !RefList {
    const refs_path = try fs.path.join(allocator, &.{ git_dir_path, "refs", "heads" });
    defer allocator.free(refs_path);
    const refs_dir = try fs.cwd().openIterableDir(refs_path, .{});
    var iter = refs_dir.iterate();
    var head_list = std.ArrayList([]const u8).init(allocator);
    while (try iter.next()) |dir| {
        try head_list.append(try allocator.dupe(u8, dir.name));
    }

    return .{
        .allocator = allocator,
        .refs = try head_list.toOwnedSlice(),
    };
}

/// Returns a list of all ref names, including heads, remotes, and tags
pub fn listRefs(allocator: mem.Allocator, git_dir_path: []const u8) !RefList {
    const refs_path = try fs.path.join(allocator, &.{ git_dir_path, "refs" });
    defer allocator.free(refs_path);

    var iter = try fs.cwd().openIterableDir(refs_path, .{});
    defer iter.close();

    var walker = try iter.walk(allocator);
    defer walker.deinit();

    var ref_list = std.ArrayList([]const u8).init(allocator);

    while (try walker.next()) |walker_entry| {
        switch (walker_entry.kind) {
            .File => {
                const ref_path = try fs.path.join(allocator, &.{ "refs", walker_entry.path });
                try ref_list.append(ref_path);
            },
            else => continue,
        }
    }

    var sorted_ref_list = try ref_list.toOwnedSlice();
    std.sort.sort([]const u8, sorted_ref_list, {}, sortStrings);

    return .{
        .allocator = allocator,
        .refs = sorted_ref_list,
    };
}

/// A list of ref names (strings)
pub const RefList = struct {
    allocator: mem.Allocator,
    refs: [][]const u8,

    pub fn deinit(self: RefList) void {
        for (self.refs) |ref| {
            self.allocator.free(ref);
        }
        self.allocator.free(self.refs);
    }
};

pub fn sortStrings(context: void, lhs: []const u8, rhs: []const u8) bool {
    _ = context;
    return mem.lessThan(u8, lhs, rhs);
}

/// Restores the contents of a file from an object
pub fn restoreFileFromObject(allocator: mem.Allocator, git_dir_path: []const u8, path: []const u8, object_name: [20]u8) !ObjectHeader {
    const file = try fs.cwd().createFile(path, .{});
    defer file.close();

    const writer = file.writer();
    return try loadObject(allocator, git_dir_path, object_name, writer);
}

/// TODO Restores the contents of a file from a commit and a path
pub fn restoreFileFromCommit(allocator: mem.Allocator, git_dir_path: []const u8, path: []const u8) !void {
    _ = git_dir_path;
    _ = allocator;
    const file = try fs.cwd().createFile(path, .{});
    defer file.close();
}

/// Returns the object that contains the file at a path in a tree
pub fn entryFromTree(allocator: mem.Allocator, git_dir_path: []const u8, tree_object_name: [20]u8, path: []const u8) ![20]u8 {
    var path_iter = mem.split(u8, path, fs.path.sep_str);
    var tree_stack = std.ArrayList(Tree).init(allocator);
    defer {
        for (tree_stack.items) |stack_tree| {
            stack_tree.deinit();
        }
        tree_stack.deinit();
    }

    const tree = try readTree(allocator, git_dir_path, tree_object_name);
    try tree_stack.append(tree);

    while (path_iter.next()) |path_segment| {
        const current_tree = tree_stack.items[tree_stack.items.len - 1];
        const final_segment = path_iter.index == null;

        const found_entry = blk: {
            for (current_tree.entries) |entry| {
                if (mem.eql(u8, entry.path, path_segment)) {
                    break :blk entry;
                }
            }
            break :blk null;
        };

        if (found_entry == null) {
            return error.NoFileInTree;
        }

        if (final_segment and found_entry.?.mode.object_type == .tree) {
            return error.EntryIsTree;
        }

        if (final_segment and found_entry.?.mode.object_type != .tree) {
            return found_entry.?.object_name;
        }

        if (found_entry.?.mode.object_type == .tree) {
            const new_tree = try readTree(allocator, git_dir_path, found_entry.?.object_name);
            try tree_stack.append(new_tree);
        }
    }

    return error.NoFileInTree;
}

/// Returns a TreeWalker
pub fn walkTree(allocator: mem.Allocator, git_dir_path: []const u8, tree_object_name: [20]u8) !TreeWalker {
    return TreeWalker.init(allocator, git_dir_path, tree_object_name);
}

/// Iterates over the contents of a tree
pub const TreeWalker = struct {
    allocator: mem.Allocator,
    tree_stack: TreeList,
    index_stack: IndexList,
    path_stack: StringList,
    name_buffer: [fs.MAX_PATH_BYTES]u8,
    name_index: usize,
    git_dir_path: []const u8,

    pub fn init(allocator: mem.Allocator, git_dir_path: []const u8, tree_object_name: [20]u8) !TreeWalker {
        var tree_walker = TreeWalker{
            .allocator = allocator,
            .tree_stack = TreeList.init(allocator),
            .index_stack = IndexList.init(allocator),
            .path_stack = StringList.init(allocator),
            .name_buffer = undefined,
            .name_index = 0,
            .git_dir_path = git_dir_path,
        };
        const tree = try readTree(allocator, git_dir_path, tree_object_name);
        try tree_walker.tree_stack.append(tree);
        try tree_walker.index_stack.append(0);

        return tree_walker;
    }

    pub fn deinit(self: *TreeWalker) void {
        for (self.tree_stack.items) |tree| {
            tree.deinit();
        }
        self.tree_stack.deinit();
        self.index_stack.deinit();
        for (self.path_stack.items) |path_item| {
            self.allocator.free(path_item);
        }
        self.path_stack.deinit();
    }

    pub fn next(self: *TreeWalker) !?Tree.Entry {
        if (self.tree_stack.items.len == 0) {
            return null;
        }

        const tree_ptr: *Tree = &self.tree_stack.items[self.tree_stack.items.len - 1];
        const index_ptr: *usize = &self.index_stack.items[self.index_stack.items.len - 1];

        const orig_entry = tree_ptr.entries[index_ptr.*];

        var buffer_alloc = std.heap.FixedBufferAllocator.init(&self.name_buffer);

        try self.path_stack.append(orig_entry.path);

        const entry_path = try fs.path.join(buffer_alloc.allocator(), self.path_stack.items );
        const entry = Tree.Entry{
            .mode = orig_entry.mode,
            .object_name = orig_entry.object_name,
            .path = entry_path,
        };

        _ = self.path_stack.pop();

        index_ptr.* += 1;

        if (entry.mode.object_type == .tree) {
            var new_tree = try readTree(self.allocator, self.git_dir_path, entry.object_name);
            try self.tree_stack.append(new_tree);
            try self.path_stack.append(try self.allocator.dupe(u8, orig_entry.path));
            try self.index_stack.append(0);
        }
        while (self.tree_stack.items.len > 0 and self.endOfTree()) {
            const tree = self.tree_stack.pop();
            tree.deinit();
            _ = self.index_stack.pop();
            if (self.path_stack.items.len != 0) {
                const path = self.path_stack.pop();
                self.allocator.free(path);
            }
        }

        return entry;
    }

    fn endOfTree(self: TreeWalker) bool {
        const tree_ptr: *Tree = &self.tree_stack.items[self.tree_stack.items.len - 1];
        const index_ptr: *usize = &self.index_stack.items[self.index_stack.items.len - 1];
        return index_ptr.* == tree_ptr.entries.len;
    }
};

pub const TreeList = std.ArrayList(Tree);
pub const IndexList = std.ArrayList(usize);
pub const StringList = std.ArrayList([]const u8);

/// Returns a Tag with a certain name
pub fn readTag(allocator: mem.Allocator, git_dir_path: []const u8, tag_object_name: [20]u8) !Tag {
    var tag_data = std.ArrayList(u8).init(allocator);
    defer tag_data.deinit();

    const object_header = try loadObject(allocator, git_dir_path, tag_object_name, tag_data.writer());
    if (object_header.@"type" != .tag) {
        return error.IncorrectObjectType;
    }

    var object_name: ?[20]u8 = null;
    var tag_type: ?ObjectType = null;
    var tag_tag: ?[]const u8 = null;
    var tagger: ?Commit.Committer = null;

    var lines = mem.split(u8, tag_data.items, "\n");
    while (lines.next()) |line| {
        if (mem.eql(u8, line, "")) {
            break;
        }
        var words = mem.tokenize(u8, line, " ");
        const key = words.next() orelse return error.InvalidTagProperty;

        if (mem.eql(u8, key, "object")) {
            const hex = words.next() orelse return error.InvalidObjectName;
            object_name = try hexDigestToObjectName(hex);
        } else if (mem.eql(u8, key, "type")) {
            const obj_type = words.next() orelse return error.InvalidObjectType;
            tag_type = std.meta.stringToEnum(ObjectType, obj_type) orelse return error.InvalidObjectType;
        } else if (mem.eql(u8, key, "tag")) {
            const tag_name = words.next() orelse return error.InvalidTagName;
            tag_tag = try allocator.dupe(u8, tag_name);
        } else if (mem.eql(u8, key, "tagger")) {
            const tag_tagger = words.rest();
            tagger = try Commit.Committer.parse(allocator, tag_tagger);
        }
    }

    const message = try allocator.dupe(u8, lines.rest());

    return Tag{
        .allocator = allocator,
        .object_name = object_name orelse return error.InvalidObjectName,
        .@"type" = tag_type orelse return error.InvalidObjectType,
        .tag = tag_tag orelse return error.InvalidTagName,
        .tagger = tagger orelse return error.InvalidTagger,
        .message = message,
    };
}

// TODO writeTag

pub const Tag = struct {
    allocator: mem.Allocator,
    object_name: [20]u8,
    @"type": ObjectType,
    tag: []const u8,
    tagger: Commit.Committer,
    message: []const u8,

    pub fn deinit(self: Tag) void {
        self.allocator.free(self.tag);
        self.tagger.deinit(self.allocator);
        self.allocator.free(self.message);
    }

    pub fn format(self: Tag, comptime fmt: []const u8, options: std.fmt.FormatOptions, out_stream: anytype) !void {
        _ = fmt;
        _ = options;
        try out_stream.print("Tag{{ object_name: {s}, type: {s}, tag: {s}, tagger: {}, message: \"{s}\" }}",
                             .{ std.fmt.fmtSliceHexLower(&self.object_name), @tagName(self.@"type"), self.tag, self.tagger, self.message });
    }
};

test "ref all" {
    std.testing.refAllDecls(@This());
}
