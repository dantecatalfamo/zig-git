const std = @import("std");
const fs = std.fs;
const os = std.os;
const mem = std.mem;
const debug = std.debug;
const testing = std.testing;

const helpers = @import("helpers.zig");
const index_zig = @import("index.zig");
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
    // TODO Look at file stats to tell if it's been modified without
    // hashing first to avoid reading every file.
    //
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
        const file_hash = try object_zig.hashFile(file);
        const stat = try file.stat();
        if (mem.eql(u8, &file_hash, &entry.object_name) and stat.mode == @as(u32, @bitCast(entry.mode))) {
            try status_diff.entries.append(.{ .path = try allocator.dupe(u8, entry.path), .status = .unmodified, .object_name = entry.object_name });
        } else {
            try status_diff.entries.append(.{ .path = try allocator.dupe(u8, entry.path), .status = .modified, .object_name = file_hash });
        }
    }

    // Checking for untracked files
    var all_path_set = std.BufSet.init(allocator);
    defer all_path_set.deinit();

    var index_path_set = std.StringHashMap(IndexObjectDetails).init(allocator);
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
        try index_path_set.put(entry.path, .{ .object_name = &entry.object_name, .mode = entry.mode });
    }

    var all_path_iter = all_path_set.iterator();
    while (all_path_iter.next()) |all_entry| {
        if (index_path_set.get(all_entry.*) != null) {
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

        var tree_path_set = std.StringHashMap(TreeObjectDetails).init(allocator);
        defer {
            var iter = tree_path_set.iterator();
            while (iter.next()) |iter_entry| {
                allocator.free(iter_entry.key_ptr.*);
            }
            tree_path_set.deinit();
        }

        while (try tree_walker.next()) |tree_entry| {
            try tree_path_set.put(try allocator.dupe(u8, tree_entry.path), .{ .object_name = tree_entry.object_name, .mode = tree_entry.mode });
        }
    }

    mem.sort(StatusDiff.Entry, status_diff.entries.items, {}, StatusDiff.Entry.lessThan);

    return status_diff;
}

const IndexObjectDetails = struct { object_name: *const [20]u8, mode: index_zig.Index.Mode };
const TreeObjectDetails = struct { object_name: [20]u8, mode: index_zig.Index.Mode };

const StatusDiff = struct {
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

    const Entry = struct {
        path: []const u8,
        status: Status,
        object_name: ?[20]u8,

        pub fn lessThan(ctx: void, a: Entry, b: Entry) bool {
            _ = ctx;
            return mem.lessThan(u8, a.path, b.path);
        }
    };

    const Status = enum {
        /// The file is modified and staged, but not yet committed
        uncommitted_modified,
        /// The file is removed from the index, but not yet committed
        uncommitted_removed,
        /// The file is added to the index, but not yet committed
        uncommitted_added,
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
