const std = @import("std");
const debug = std.debug;
const fs = std.fs;
const mem = std.mem;
const os = std.os;
const testing = std.testing;

const helpers = @import("helpers.zig");
const lessThanStrings = helpers.lessThanStrings;
const hexDigestToObjectName = helpers.hexDigestToObjectName;

/// Recursively resolves the HEAD until an object name is found.
pub fn resolveHead(allocator: mem.Allocator, git_dir_path: []const u8) !?[20]u8 {
    return try resolveRef(allocator, git_dir_path, "HEAD");
}

/// Recursively resolves refs until an object name is found.
pub fn resolveRef(allocator: mem.Allocator, git_dir_path: []const u8, ref: []const u8) !?[20]u8 {
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
            .file => {
                const ref_path = try fs.path.join(allocator, &.{ "refs", walker_entry.path });
                try ref_list.append(ref_path);
            },
            else => continue,
        }
    }

    var sorted_ref_list = try ref_list.toOwnedSlice();
    mem.sort([]const u8, sorted_ref_list, {}, lessThanStrings);

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
