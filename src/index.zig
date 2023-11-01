const std = @import("std");
const fs = std.fs;
const os = std.os;
const mem = std.mem;
const debug = std.debug;
const testing = std.testing;

const helpers = @import("helpers.zig");
const object_zig = @import("object.zig");
const repoToGitDir = helpers.repoToGitDir;

const saveObject = @import("object.zig").saveObject;

pub fn modifiedFromIndex(allocator: mem.Allocator, repo_path: []const u8) !*IndexDiff {
    const index = try readIndex(allocator, repo_path);
    defer index.deinit();

    var diff_entries = IndexDiff.EntryList.init(allocator);

    var path_buffer: [fs.MAX_PATH_BYTES]u8 = undefined;
    // TODO Look at file stats to tell if it's been modified without
    // hashing first to avoid reading every file.
    //
    // TODO Check if file permissions have changed.
    for (index.entries.items) |entry| {
        var path_allocator = std.heap.FixedBufferAllocator.init(&path_buffer);
        const full_path = try fs.path.join(path_allocator.allocator(), &.{ repo_path, entry.path });
        const file = fs.cwd().openFile(full_path, .{}) catch |err| switch (err) {
            error.FileNotFound => {
                try diff_entries.append(.{ .path = try allocator.dupe(u8, entry.path), .status = .removed });
                continue;
            },
            else => return err,
        };
        const file_hash = try object_zig.hashFile(file);
        if (mem.eql(u8, &file_hash, &entry.object_name)) {
            try diff_entries.append(.{ .path = try allocator.dupe(u8, entry.path), .status = .unmodified });
        } else {
            try diff_entries.append(.{ .path = try allocator.dupe(u8, entry.path), .status = .modified });
        }
    }

    var all_path_set = std.BufSet.init(allocator);
    defer all_path_set.deinit();

    var index_path_set = std.BufSet.init(allocator);
    defer index_path_set.deinit();

    var dir_iterable = try fs.cwd().openIterableDir(repo_path, .{});
    var walker = try dir_iterable.walk(allocator);
    defer walker.deinit();

    while (try walker.next()) |dir_entry| {
        switch (dir_entry.kind) {
            .sym_link, .file => {
                if (mem.startsWith(u8, dir_entry.path, ".git") or mem.indexOf(u8, dir_entry.path, fs.path.sep_str ++ ".git") != null) {
                    continue;
                }
                try all_path_set.insert(dir_entry.path);
            },
            else => continue,
        }
    }

    for (index.entries.items) |entry| {
        try index_path_set.insert(entry.path);
    }

    var all_path_iter = all_path_set.iterator();
    while (all_path_iter.next()) |all_entry| {
        if (!index_path_set.contains(all_entry.*)) {
            try diff_entries.append(.{ .path = try allocator.dupe(u8, all_entry.*), .status = .untracked });
        }
    }

    mem.sort(IndexDiff.Entry, diff_entries.items, {}, IndexDiff.Entry.lessThan);

    var index_diff = try allocator.create(IndexDiff);
    index_diff.*.entries = diff_entries;
    return index_diff;
}

const IndexDiff = struct {
    entries: EntryList,

    pub fn deinit(self: *const IndexDiff) void {
        for (self.entries.items) |entry| {
            self.entries.allocator.free(entry.path);
        }
        self.entries.deinit();
        self.entries.allocator.destroy(self);
    }

    const EntryList = std.ArrayList(Entry);

    const Entry = struct {
        path: []const u8,
        status: Status,

        pub fn lessThan(ctx: void, a: Entry, b: Entry) bool {
            _ = ctx;
            return mem.lessThan(u8, a.path, b.path);
        }
    };

    const Status = enum {
        untracked,
        unmodified,
        modified,
        removed,
    };
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
        const mode: Index.Mode = @bitCast(try index_reader.readIntBig(u32));
        const uid = try index_reader.readIntBig(u32);
        const gid = try index_reader.readIntBig(u32);
        const file_size = try index_reader.readIntBig(u32);
        const object_name = try index_reader.readBytesNoEof(20);

        const flags: Index.Flags = @bitCast(try index_reader.readIntBig(u16));
        const extended_flags = blk: {
            if (header.version > 2 and flags.extended) {
                const extra_flgs = try index_reader.readIntBig(u16);
                break :blk @as(Index.ExtendedFlags, @bitCast(extra_flgs));
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
    try index_writer.writeIntBig(u32, @as(u32, @truncate(index.entries.items.len)));

    var entries: []*const Index.Entry = try allocator.alloc(*Index.Entry, index.entries.items.len);
    defer allocator.free(entries);

    for (index.entries.items, 0..) |*entry, idx| {
        entries[idx] = entry;
    }

    mem.sort(*const Index.Entry, entries, {}, sortIndexEntries);

    for (entries) |entry| {
        var counter = std.io.countingWriter(index_writer);
        const counting_writer = counter.writer();

        try counting_writer.writeIntBig(u32, entry.ctime_s);
        try counting_writer.writeIntBig(u32, entry.ctime_n);
        try counting_writer.writeIntBig(u32, entry.mtime_s);
        try counting_writer.writeIntBig(u32, entry.mtime_n);
        try counting_writer.writeIntBig(u32, entry.dev);
        try counting_writer.writeIntBig(u32, entry.ino);
        try counting_writer.writeIntBig(u32, @as(u32, @bitCast(entry.mode)));
        try counting_writer.writeIntBig(u32, entry.uid);
        try counting_writer.writeIntBig(u32, entry.gid);
        try counting_writer.writeIntBig(u32, entry.file_size);
        try counting_writer.writeAll(&entry.object_name);

        try counting_writer.writeIntBig(u16, @as(u16, @bitCast(entry.flags)));
        if (index.header.version > 2 and entry.flags.extended and entry.extended_flags != null) {
            try counting_writer.writeIntBig(u16, @as(u16, @bitCast(entry.extended_flags.?)));
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

// FIXME This is not super efficient. It traverses all directories,
// including .git directories, and then rejects the files when it
// calls `addFileToIndex`. I don't think there's a way to filter
// directories using openIterableDir at the moment.
/// Recursively add files to an index
pub fn addFilesToIndex(allocator: mem.Allocator, repo_path: []const u8, index: *Index, dir_path: []const u8) !void {
    var dir_iterable = try fs.cwd().openIterableDir(dir_path, .{});
    defer dir_iterable.close();

    var walker = try dir_iterable.walk(allocator);
    defer walker.deinit();

    while (try walker.next()) |walker_entry| {
        switch (walker_entry.kind) {
            .sym_link, .file => {
                const joined_path = try fs.path.join(allocator, &.{ dir_path, walker_entry.path });
                defer allocator.free(joined_path);
                try addFileToIndex(allocator, repo_path, index, joined_path);
            },
            .directory => continue,
            else => |tag| std.debug.print("Cannot add type {s} to index\n", .{ @tagName(tag) }),
        }
    }
}

/// Add the file at the path to an index
pub fn addFileToIndex(allocator: mem.Allocator, repo_path: []const u8, index: *Index, file_path: []const u8) !void {
    var path_iter = mem.split(u8, file_path, fs.path.sep_str);
    while (path_iter.next()) |dir| {
        // Don't add .git files to the index
        if (mem.eql(u8, dir, ".git")) {
            return;
        }
    }

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
            break :blk @as(u12, @truncate(repo_relative_path.len));
        }
    };

    const git_dir_path = try repoToGitDir(allocator, repo_path);
    defer allocator.free(git_dir_path);

    const object_name = try saveObject(allocator, git_dir_path, data, .blob);

    const entry = Index.Entry{
        .ctime_s = @intCast(stat.ctime().tv_sec),
        .ctime_n = @intCast(stat.ctime().tv_nsec),
        .mtime_s = @intCast(stat.mtime().tv_sec),
        .mtime_n = @intCast(stat.mtime().tv_nsec),
        .dev = @intCast(stat.dev),
        .ino = @intCast(stat.ino),
        .mode = @bitCast(@as(u32, stat.mode)),
        .uid = stat.uid,
        .gid = stat.gid,
        .file_size = @intCast(stat.size),
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

pub fn removeFileFromIndex(allocator: mem.Allocator, repo_path: []const u8, index: *Index, file_path: []const u8) !void {
    const absolute_repo_path = try fs.cwd().realpathAlloc(allocator, repo_path);
    defer allocator.free(absolute_repo_path);
    const absolute_file_path = try fs.cwd().realpathAlloc(allocator, file_path);
    defer allocator.free(absolute_file_path);
    const repo_relative_path = try fs.path.relative(allocator, absolute_repo_path, absolute_file_path);
    defer allocator.free(repo_relative_path);

    var removed = false;
    for (index.entries.items, 0..) |entry, idx| {
        if (mem.eql(u8, entry.path, repo_relative_path)) {
            const removed_entry = index.entries.orderedRemove(idx);
            removed_entry.deinit(index.entries.allocator);
            removed = true;
            break;
        }
    }

    if (!removed) {
        return error.FileNotInIndex;
    }
}

pub const IndexList = std.ArrayList(usize);

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
            try out_stream.print("Index.Entry{{ mode: {o}, object_name: {s}, size: {d:5}, path: {s} }}", .{ @as(u32, @bitCast(self.mode)), std.fmt.fmtSliceHexLower(&self.object_name), self.file_size, self.path });
        }
    };

    pub const EntryList = std.ArrayList(Entry);

    pub const Mode = packed struct(u32) {
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
