const std = @import("std");
const debug = std.debug;
const fs = std.fs;
const mem = std.mem;
const os = std.os;
const testing = std.testing;

const object_zig = @import("object.zig");
const loadObject = object_zig.loadObject;
const saveObject = object_zig.saveObject;

const tree_zig = @import("tree.zig");

const helpers = @import("helpers.zig");
const ObjectNameList = helpers.ObjectNameList;
const hexDigestToObjectName = helpers.hexDigestToObjectName;

/// Restore all of a commit's files in a repo
pub fn restoreCommit(allocator: mem.Allocator, repo_path: []const u8, commit_object_name: [20]u8) !void {
    const git_dir_path = try helpers.repoToGitDir(allocator, repo_path);
    defer allocator.free(git_dir_path);

    const commit = try readCommit(allocator, git_dir_path, commit_object_name);
    defer commit.deinit();

    try tree_zig.restoreTree(allocator, repo_path, commit.tree);
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
    if (commit_object_header.type != .commit) {
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
            // PGP signatures seem to have a trailing line with one space
            const trailing_line = lines.next() orelse return error.MissingTrailingPGPLine;
            if (!mem.eql(u8, trailing_line, " ")) {
                std.debug.print("Trailing PGP line: \"{s}\"\n", .{ trailing_line });
                return error.TrailingPGPLineNotEmpty;
            }
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
            const timezone: u16 = @intCast(@abs(self.timezone));
            try out_stream.print("{s} <{s}> {d} {c}{d:0>4}", .{ self.name, self.email, self.time, sign, timezone });
        }
    };
};
