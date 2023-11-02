const std = @import("std");
const debug = std.debug;
const fs = std.fs;
const mem = std.mem;
const os = std.os;
const testing = std.testing;

const object_zig = @import("object.zig");
const saveObject = object_zig.saveObject;
const loadObject = object_zig.loadObject;

const index_zig = @import("index.zig");
const Index = index_zig.Index;
const IndexList = index_zig.IndexList;
const readIndex = index_zig.readIndex;
const addFileToIndex = index_zig.addFileToIndex;

const helpers = @import("helpers.zig");
const StringList = helpers.StringList;

pub fn restoreTree(allocator: mem.Allocator, repo_path: []const u8, tree_object_name: [20]u8) !*Index {
    const git_dir_path = try helpers.repoToGitDir(allocator, repo_path);
    defer allocator.free(git_dir_path);

    var tree_iter = try walkTree(allocator, git_dir_path, tree_object_name);
    defer tree_iter.deinit();

    var index = try Index.init(allocator);
    errdefer index.deinit();

    var path_buffer: [fs.MAX_PATH_BYTES]u8 = undefined;

    while (try tree_iter.next()) |entry| {
        if (entry.mode.object_type != .regular_file) {
            // TODO Handle restoring other types of files, being more
            // efficient than just overwriting every file
            continue;
        }
        var path_allocator = std.heap.FixedBufferAllocator.init(&path_buffer);
        const entry_full_path = try fs.path.join(path_allocator.allocator(), &.{ repo_path, entry.path });
        const object_name = entry.object_name;

        const file = try fs.cwd().createFile(entry_full_path, .{});
        errdefer file.close();

        // TODO We could check I suppose, maybe later
        _ = try object_zig.loadObject(allocator, git_dir_path, object_name, file.writer());
        try file.sync();
        file.close();

        try addFileToIndex(allocator, repo_path, index, entry_full_path);

        std.debug.print("Restored File: [{s}] {s}, full_path: {s}\n", .{ std.fmt.fmtSliceHexLower(&entry.object_name), entry.path, entry_full_path });
    }

    return index;
}

pub fn readTree(allocator: mem.Allocator, git_dir_path: []const u8, object_name: [20]u8) !Tree {
    var entries = std.ArrayList(Tree.Entry).init(allocator);
    var object = std.ArrayList(u8).init(allocator);
    defer object.deinit();

    const object_type = try loadObject(allocator, git_dir_path, object_name, object.writer());
    if (object_type.type != .tree) {
        return error.IncorrectObjectType;
    }

    var buffer = std.io.fixedBufferStream(object.items);
    const object_reader = buffer.reader();

    while (buffer.pos != object.items.len) {
        var mode_buffer: [16]u8 = undefined;
        const mode_text = try object_reader.readUntilDelimiter(&mode_buffer, ' ');
        const mode = @as(Index.Mode, @bitCast(try std.fmt.parseInt(u32, mode_text, 8)));
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

    mem.sort(Tree.Entry, tree.entries, {}, sortTreeEntries);

    for (tree.entries) |entry| {
        try tree_writer.print("{o} {s}\x00", .{ @as(u32, @bitCast(entry.mode)), entry.path });
        try tree_writer.writeAll(&entry.object_name);
    }

    return saveObject(allocator, git_dir_path, tree_data.items, .tree);
}

fn sortTreeEntries(context: void, lhs: Tree.Entry, rhs: Tree.Entry) bool {
    _ = context;
    return mem.lessThan(u8, lhs.path, rhs.path);
}

pub const TreeList = std.ArrayList(Tree);

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

            try out_stream.print("Tree.Entry{{ mode: {o: >6}, object_name: {s}, path: {s} }}", .{ @as(u32, @bitCast(self.mode)), std.fmt.fmtSliceHexLower(&self.object_name), self.path });
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

        const entry_path = try fs.path.join(buffer_alloc.allocator(), self.path_stack.items);
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

/// Returns the object that contains the file at a path in a tree
pub fn entryFromTree(allocator: mem.Allocator, git_dir_path: []const u8, tree_object_name: [20]u8, path: []const u8) ![20]u8 {
    var path_iter = mem.split(u8, path, fs.path.sep_str);
    var tree_stack = TreeList.init(allocator);
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
