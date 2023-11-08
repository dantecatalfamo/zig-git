const std = @import("std");
const fs = std.fs;
const os = std.os;
const mem = std.mem;
const debug = std.debug;
const testing = std.testing;

const helpers = @import("helpers.zig");
const index_zig = @import("index.zig");
const IndexEntry = index_zig.Index.Entry;
const readIndex = index_zig.readIndex;
const object_zig = @import("object.zig");
const repoToGitDir = helpers.repoToGitDir;
const tree_zig = @import("tree.zig");
const ref_zig = @import("ref.zig");
const commit_zig = @import("commit.zig");

const saveObject = @import("object.zig").saveObject;

/// Compare the working area to the index file and return the results.
pub fn repoStatus(allocator: mem.Allocator, repo_path: []const u8) !*StatusDiff {
    const git_dir_path = try repoToGitDir(allocator, repo_path);
    defer allocator.free(git_dir_path);

    const index = try readIndex(allocator, repo_path);
    defer index.deinit();

    var status_diff = try StatusDiff.init(allocator);
    errdefer status_diff.deinit();

    var path_buffer: [fs.MAX_PATH_BYTES]u8 = undefined;

    // Checking for removed, modified, or unmodified files
    for (index.entries.items) |entry| {
        if (entry.mode.object_type != .regular_file) {
            // TODO Is it possible to check for gitlink and symlink updates?
            continue;
        }
        var path_allocator = std.heap.FixedBufferAllocator.init(&path_buffer);
        const full_path = try fs.path.join(path_allocator.allocator(), &.{ repo_path, entry.path });
        const file = fs.cwd().openFile(full_path, .{}) catch |err| switch (err) {
            error.FileNotFound => {
                try status_diff.entries.append(.{ .path = try allocator.dupe(u8, entry.path), .status = .removed, .object_name = entry.object_name });
                continue;
            },
            else => return err,
        };
        defer file.close();

        // If the file metadata isn't changed, assume the file isn't
        // for speed
        if (!try fileStatChangedFromEntry(file, entry)) {
            continue;
        }
        const stat = try file.stat();
        const file_hash = try object_zig.hashFile(file);
        if (!mem.eql(u8, &file_hash, &entry.object_name) or stat.mode != @as(u32, @bitCast(entry.mode))) {
            try status_diff.entries.append(.{ .path = try allocator.dupe(u8, entry.path), .status = .modified, .object_name = file_hash });
        }
    }

    // Checking for untracked files
    var all_path_set = std.BufSet.init(allocator);
    defer all_path_set.deinit();

    var index_path_set = std.StringHashMap(ObjectDetails).init(allocator);
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
        try index_path_set.put(entry.path, .{ .object_name = entry.object_name, .mode = entry.mode });
    }

    var all_path_iter = all_path_set.iterator();
    while (all_path_iter.next()) |all_entry| {
        if (index_path_set.get(all_entry.*) == null) {
            try status_diff.entries.append(.{ .path = try allocator.dupe(u8, all_entry.*), .status = .untracked, .object_name = null });
        }
    }

    // Checking for files that are staged but not committed
    // This includes deleted, modified, new files (oh no)
    if (try ref_zig.resolveHead(allocator, git_dir_path)) |commit_object_name| {
        const commit = try commit_zig.readCommit(allocator, git_dir_path, commit_object_name);
        defer commit.deinit();

        const tree_object_name = commit.tree;
        var tree_walker = try tree_zig.walkTree(allocator, git_dir_path, tree_object_name);
        defer tree_walker.deinit();

        var tree_path_set = std.StringHashMap(ObjectDetails).init(allocator);
        defer {
            var iter = tree_path_set.iterator();
            while (iter.next()) |iter_entry| {
                allocator.free(iter_entry.key_ptr.*);
            }
            tree_path_set.deinit();
        }

        while (try tree_walker.next()) |tree_entry| {
            try tree_path_set.put(try allocator.dupe(u8, tree_entry.path), .{ .object_name = tree_entry.object_name, .mode = tree_entry.mode });
            if (index_path_set.get(tree_entry.path)) |index_entry| {
                // In index and tree
                if (!mem.eql(u8, &index_entry.object_name, &tree_entry.object_name)) {
                    // Object names don't match
                    try status_diff.entries.append(.{ .path = try allocator.dupe(u8, tree_entry.path), .status = .staged_modified, .object_name = tree_entry.object_name });
                }
            } else {
                // In tree, not in index
                // TODO How to deal with staged removal of non-regular files
                if (tree_entry.mode.object_type != .regular_file) {
                    continue;
                }
                try status_diff.entries.append(.{ .path = try allocator.dupe(u8, tree_entry.path), .status = .staged_removed, .object_name = tree_entry.object_name });
            }
        }

        var index_iter = index_path_set.iterator();
        while (index_iter.next()) |index_entry| {
            if (tree_path_set.contains(index_entry.key_ptr.*)) {
                continue;
            }
            // In index, not in tree
            try status_diff.entries.append(.{ .path = try allocator.dupe(u8, index_entry.key_ptr.*), .status = .staged_added, .object_name = index_entry.value_ptr.object_name });
        }
    }

    mem.sort(StatusDiff.Entry, status_diff.entries.items, {}, StatusDiff.Entry.lessThan);

    return status_diff;
}

const ObjectDetails = struct { object_name: [20]u8, mode: index_zig.Index.Mode };

pub fn fileStatChangedFromEntry(file: fs.File, entry: IndexEntry) !bool {
    const stat = try os.fstat(file.handle);
    const ctime = stat.ctime();
    const mtime = stat.mtime();
    if (ctime.tv_sec != entry.ctime_s) return true;
    if (ctime.tv_nsec != entry.ctime_n) return true;
    if (mtime.tv_sec != entry.mtime_s) return true;
    if (mtime.tv_nsec != entry.mtime_n) return true;
    if (stat.ino != entry.ino) return true;
    if (stat.dev != entry.dev) return true;
    if (stat.mode != @as(u32, @bitCast(entry.mode))) return true;
    if (stat.size != entry.file_size) return true;
    return false;
}

pub const StatusDiff = struct {
    entries: EntryList,

    pub fn init(allocator: mem.Allocator) !*StatusDiff {
        var status_diff = try allocator.create(StatusDiff);
        status_diff.entries = EntryList.init(allocator);
        return status_diff;
    }

    pub fn deinit(self: *const StatusDiff) void {
        for (self.entries.items) |entry| {
            self.entries.allocator.free(entry.path);
        }
        self.entries.deinit();
        self.entries.allocator.destroy(self);
    }

    const EntryList = std.ArrayList(Entry);

    pub const Entry = struct {
        path: []const u8,
        status: Status,
        object_name: ?[20]u8,

        pub fn lessThan(ctx: void, a: Entry, b: Entry) bool {
            _ = ctx;
            return mem.lessThan(u8, a.path, b.path);
        }
    };

    pub const Status = enum {
        /// The file is modified and staged, but not yet committed
        staged_modified,
        /// The file is removed from the index, but not yet committed
        staged_removed,
        /// The file is added to the index, but not yet committed
        staged_added,
        /// The file is not tracked by the index
        untracked,
        /// The file has not been modified compared to the index
        unmodified,
        /// The file is different from the version tracked by the index
        modified,
        /// The file is listed in the index, but does not exist on disk
        removed,
    };
};
