const std = @import("std");
const os = std.os;
const mem = std.mem;
const fs = std.fs;

const object_zig = @import("object.zig");
const loadObject = object_zig.loadObject;
const saveObject = object_zig.saveObject;
const ObjectType = object_zig.ObjectType;
const ObjectHeader = object_zig.ObjectHeader;

const index_zig = @import("index.zig");
const Index = index_zig.Index;
const readIndex = index_zig.readIndex;
const writeIndex = index_zig.writeIndex;
const addFilesToIndex = index_zig.addFilesToIndex;
const addFileToIndex = index_zig.addFileToIndex;
const removeFileFromIndex = index_zig.removeFileFromIndex;
const modifiedFromIndex = index_zig.modifiedFromIndex;

const helpers = @import("helpers.zig");
const repoToGitDir = helpers.repoToGitDir;
const findRepoRoot = helpers.findRepoRoot;
const ObjectNameList = helpers.ObjectNameList;
const hexDigestToObjectName = helpers.hexDigestToObjectName;
const lessThanStrings = helpers.lessThanStrings;

const init_zig = @import("init.zig");
const initialize = init_zig.initialize;
const initializeBare = init_zig.initializeBare;

const tree_zig = @import("tree.zig");
const indexToTree = tree_zig.indexToTree;
const TreeList = tree_zig.TreeList;
const walkTree = tree_zig.walkTree;
const readTree = tree_zig.readTree;
const restoreTree = tree_zig.restoreTree;

const commit_zig = @import("commit.zig");
const Commit = commit_zig.Commit;
const writeCommit = commit_zig.writeCommit;
const readCommit = commit_zig.readCommit;
const restoreCommit = commit_zig.restoreCommit;

const ref_zig = @import("ref.zig");
const resolveRef = ref_zig.resolveRef;
const currentRef = ref_zig.currentRef;
const updateHead = ref_zig.updateHead;
const updateRef = ref_zig.updateRef;
const currentHeadRef = ref_zig.currentHeadRef;
const listHeadRefs = ref_zig.listHeadRefs;
const listRefs = ref_zig.listRefs;
const readRef = ref_zig.readRef;
const resolveHead = ref_zig.resolveHead;
const currentHead = ref_zig.currentHead;
const resolveRefOrObjectName = ref_zig.resolveRefOrObjectName;
const cannonicalizeRef = ref_zig.cannonicalizeRef;

const tag_zig = @import("tag.zig");
const readTag = tag_zig.readTag;

const status_zig = @import("status.zig");
const repoStatus = status_zig.repoStatus;

const pack_zig = @import("pack.zig");
const Pack = pack_zig.Pack;

const pack_index_zig = @import("pack_index.zig");
const PackIndex = pack_index_zig.PackIndex;

pub fn main() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{ .stack_trace_frames = 12 }){};
    var allocator = gpa.allocator();
    defer _ = gpa.deinit();

    var args = std.process.args();
    _ = args.next();

    const subcommand = blk: {
        const str = args.next() orelse break :blk null;
        break :blk std.meta.stringToEnum(SubCommands, str);
    } orelse {
        std.debug.print("No subcommand specified.\nAvailable subcommands:\n", .{});
        for (std.meta.fieldNames(SubCommands)) |field| {
            std.debug.print("{s}\n", .{field});
        }
        return;
    };

    switch (subcommand) {
        .index => {
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
        },
        .init => {
            const path = blk: {
                if (args.next()) |valid_path| {
                    break :blk valid_path;
                } else {
                    break :blk ".";
                }
            };
            try initialize(allocator, path);
            std.debug.print("initialized empty repository {s}\n", .{ path });
        },
        .add => {
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
                .directory => try addFilesToIndex(allocator, repo_path, index, file_path),
                .sym_link, .file, => try addFileToIndex(allocator, repo_path, index, file_path),
                else => |tag| std.debug.print("Cannot add file of type {s} to index\n", .{ @tagName(tag) }),
            }

            try writeIndex(allocator, repo_path, index);
        },
        .commit => {
            const repo_root = try findRepoRoot(allocator);
            defer allocator.free(repo_root);

            const git_dir_path = try repoToGitDir(allocator, repo_root);
            defer allocator.free(git_dir_path);

            const tree = try indexToTree(allocator, repo_root);
            const committer = Commit.Committer{
                .name = "Gaba Goul",
                .email = "gaba@cool.ca",
                .time = std.time.timestamp(),
                .timezone = 0,
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
                .message = "Commit test!",
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
        },
        .branches => {
            const repo_path = try findRepoRoot(allocator);
            defer allocator.free(repo_path);

            const git_dir_path = try repoToGitDir(allocator, repo_path);
            defer allocator.free(git_dir_path);

            const current_ref = try currentHeadRef(allocator, git_dir_path);

            defer if (current_ref) |valid_ref| allocator.free(valid_ref);

            var refs = try listHeadRefs(allocator, git_dir_path);
            defer refs.deinit();

            mem.sort([]const u8, refs.refs, {}, lessThanStrings);

            for (refs.refs) |ref| {
                const indicator: u8 = blk: {
                    if (current_ref) |valid_ref| {
                        break :blk if (mem.eql(u8, valid_ref, ref)) '*' else ' ';
                    } else break :blk ' ';
                };
                std.debug.print("{c} {s}\n", .{ indicator, ref });
            }
        },
        .@"branch-create" =>  {
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
        },
        .refs => {
            const repo_path = try findRepoRoot(allocator);
            defer allocator.free(repo_path);

            const git_dir_path = try repoToGitDir(allocator, repo_path);
            defer allocator.free(git_dir_path);

            const refs = try listRefs(allocator, git_dir_path);
            defer refs.deinit();

            for (refs.refs) |ref| {
                std.debug.print("{s}\n", .{ ref });
            }
        },
        .@"read-tree" => {
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
        },
        .@"read-commit" => {
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
        },
        .root => {
            const repo_path = try findRepoRoot(allocator);
            defer allocator.free(repo_path);

            std.debug.print("{s}\n", .{ repo_path });
        },
        .@"read-ref" => {
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
        },
        .@"read-tag" => {
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
        },
        .@"read-pack" => {
            const pack_name = args.next() orelse {
                std.debug.print("No pack specified\n", .{});
                return;
            };

            const repo_path = try findRepoRoot(allocator);
            defer allocator.free(repo_path);

            const git_dir_path = try repoToGitDir(allocator, repo_path);
            defer allocator.free(git_dir_path);

            const packfile_name = try std.fmt.allocPrint(allocator, "pack-{s}.pack", .{ pack_name });
            defer allocator.free(packfile_name);

            const pack_path = try fs.path.join(allocator, &.{ git_dir_path, "objects", "pack", packfile_name });
            defer allocator.free(pack_path);

            const pack_file = try fs.cwd().openFile(pack_path, .{});
            defer pack_file.close();

            const pack = try Pack.init(allocator, pack_file);
            defer pack.deinit();

            std.debug.print("{any}\n", .{ pack });

            // try pack.validate();

            var iter = try pack.iterator();
            defer iter.deinit();

            while (try iter.next()) |entry| {
                std.debug.print("{s} ({d}): {any}\n", .{ std.fmt.fmtSliceHexLower(&entry.object_name), entry.offset, entry.object_reader.header });
            }
        },
        .@"read-pack-index" => {
            const pack_index_name = args.next() orelse {
                std.debug.print("No pack specified\n", .{});
                return;
            };

            const pack_search = args.next() orelse {
                std.debug.print("No search name\n", .{});
                return;
            };

            const repo_path = try findRepoRoot(allocator);
            defer allocator.free(repo_path);

            const git_dir_path = try repoToGitDir(allocator, repo_path);
            defer allocator.free(git_dir_path);

            const index_file_name = try std.fmt.allocPrint(allocator, "pack-{s}.idx", .{ pack_index_name });
            defer allocator.free(index_file_name);

            const pack_path = try fs.path.join(allocator, &.{ git_dir_path, "objects", "pack", index_file_name });
            defer allocator.free(pack_path);

            const pack_index = try PackIndex.init(pack_path);
            defer pack_index.deinit();

            const name = try helpers.hexDigestToObjectName(pack_search);
            if (try pack_index.find(name)) |offset| {
                std.debug.print("offset: {d}\n", .{offset});
            } else {
                std.debug.print("offset not found\n", .{});
            }
        },
        .log => {
            const repo_path = try findRepoRoot(allocator);
            defer allocator.free(repo_path);

            const git_dir_path = try repoToGitDir(allocator, repo_path);
            defer allocator.free(git_dir_path);

            const commit_object_name = try resolveHead(allocator, git_dir_path) orelse return;

            var commit: ?*Commit = null;
            commit = try readCommit(allocator, git_dir_path, commit_object_name);

            std.debug.print("{s}: ", .{std.fmt.fmtSliceHexLower(&commit_object_name)});
            while (commit) |valid_commit| {
                const old_commit = valid_commit;
                defer old_commit.deinit();

                std.debug.print("{}\n", .{valid_commit});
                if (valid_commit.parents.items.len >= 1) {
                    // HACK We only look at the first parent, we should
                    // look at all (for merges, etc.)
                    std.debug.print("{s}: ", .{std.fmt.fmtSliceHexLower(&valid_commit.parents.items[0])});
                    commit = try readCommit(allocator, git_dir_path, valid_commit.parents.items[0]);
                } else {
                    commit = null;
                }
            }
        },
        .@"search-pack" => {
            const pack_search = args.next() orelse {
                std.debug.print("No search name\n", .{});
                return;
            };

            const object_name = try hexDigestToObjectName(pack_search);

            const repo_path = try findRepoRoot(allocator);
            defer allocator.free(repo_path);

            const git_dir_path = try repoToGitDir(allocator, repo_path);
            defer allocator.free(git_dir_path);

            const result = try pack_index_zig.searchPackIndicies(allocator, git_dir_path, object_name);
            std.debug.print("Pack: {s}, Offset: {d}\n", .{ std.fmt.fmtSliceHexLower(&result.pack), result.offset });
        },
        .status => {
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
            const modifed_from_index = try repoStatus(allocator, repo_path);
            defer modifed_from_index.deinit();

            std.debug.print("\n", .{});
            var clean = true;
            for (modifed_from_index.entries.items) |entry| {
                if (entry.status != .staged_added) {
                    continue;
                }
                clean = false;
                std.debug.print("{s}: {s}: {s}\n", .{ @tagName(entry.status), entry.path, std.fmt.fmtSliceHexLower(&entry.object_name.?) });
            }
            for (modifed_from_index.entries.items) |entry| {
                if (entry.status != .staged_modified) {
                    continue;
                }
                clean = false;
                std.debug.print("{s}: {s}: {s}\n", .{ @tagName(entry.status), entry.path, std.fmt.fmtSliceHexLower(&entry.object_name.?) });
            }
            for (modifed_from_index.entries.items) |entry| {
                if (entry.status != .staged_removed) {
                    continue;
                }
                clean = false;
                std.debug.print("{s}: {s}: {s}\n", .{ @tagName(entry.status), entry.path, std.fmt.fmtSliceHexLower(&entry.object_name.?) });
            }
            for (modifed_from_index.entries.items) |entry| {
                if (entry.status != .modified) {
                    continue;
                }
                clean = false;
                std.debug.print("{s}: {s}: {s}\n", .{ @tagName(entry.status), entry.path, std.fmt.fmtSliceHexLower(&entry.object_name.?) });
            }
            for (modifed_from_index.entries.items) |entry| {
                if (entry.status != .removed) {
                    continue;
                }
                clean = false;
                std.debug.print("{s}: {s}: {s}\n", .{ @tagName(entry.status), entry.path, std.fmt.fmtSliceHexLower(&entry.object_name.?) });
            }
            // TODO commented out until .gitignore works, too many
            // junk files displayed
            //
            // for (modifed_from_index.entries.items) |entry| {
            //     if (entry.status != .untracked) {
            //         continue;
            //     }
            //     std.debug.print("{s}: {s}\n", .{ @tagName(entry.status), entry.path });
            // }
            if (clean) {
                std.debug.print("Clean working tree\n", .{});
            }
        },
        .rm => {
            const file_path = blk: {
                if (args.next()) |valid_path| {
                    break :blk valid_path;
                }
                std.debug.print("Must specify file path\n", .{});
                return error.NoFilePath;
            };

            const repo_path = try findRepoRoot(allocator);
            defer allocator.free(repo_path);

            var index = try readIndex(allocator, repo_path);
            defer index.deinit();

            try removeFileFromIndex(allocator, repo_path, index, file_path);

            try writeIndex(allocator, repo_path, index);
        },
        .checkout => {
            const ref_or_object_name = args.next() orelse {
                std.debug.print("No commit specified\n", .{});
                return;
            };

            const repo_path = try findRepoRoot(allocator);
            defer allocator.free(repo_path);

            const git_dir_path = try repoToGitDir(allocator, repo_path);
            defer allocator.free(git_dir_path);

            const commit_object_name = try resolveRefOrObjectName(allocator, git_dir_path, ref_or_object_name) orelse {
                std.debug.print("Invalid ref or commit hash\n", .{});
                return;
            };

            const new_ref = try cannonicalizeRef(allocator, git_dir_path, ref_or_object_name) orelse {
                std.debug.print("Invalid ref or commit hash\n", .{});
                return;
            };
            defer new_ref.deinit(allocator);

            // TODO doesn't remove files that were added since
            // restored commit
            const new_index = try restoreCommit(allocator, repo_path, commit_object_name);
            defer new_index.deinit();

            try writeIndex(allocator, repo_path, new_index);
            try updateHead(allocator, git_dir_path, new_ref);
        }
    }
}

const SubCommands = enum {
    add,
    branches,
    @"branch-create",
    checkout,
    commit,
    index,
    init,
    log,
    @"read-commit",
    @"read-pack",
    @"read-pack-index",
    @"read-ref",
    @"read-tag",
    @"read-tree",
    refs,
    rm,
    root,
    @"search-pack",
    status,
    // TODO notes
};

/// TODO Restores the contents of a file from a commit and a path
pub fn restoreFileFromCommit(allocator: mem.Allocator, git_dir_path: []const u8, path: []const u8) !void {
    _ = git_dir_path;
    _ = allocator;
    const file = try fs.cwd().createFile(path, .{});
    defer file.close();
}

test "ref all" {
    std.testing.refAllDecls(@This());
}
