const std = @import("std");
const debug = std.debug;
const fs = std.fs;
const mem = std.mem;
const os = std.os;
const testing = std.testing;

const object_zig = @import("object.zig");
const loadObject = object_zig.loadObject;
const ObjectType = object_zig.ObjectType;

const Commit = @import("commit.zig").Commit;

const helpers = @import("helpers.zig");
const hexDigestToObjectName = helpers.hexDigestToObjectName;

/// Returns a Tag with a certain name
pub fn readTag(allocator: mem.Allocator, git_dir_path: []const u8, tag_object_name: [20]u8) !Tag {
    var tag_data = std.ArrayList(u8).init(allocator);
    defer tag_data.deinit();

    const object_header = try loadObject(allocator, git_dir_path, tag_object_name, tag_data.writer());
    if (object_header.type != .tag) {
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
        .type = tag_type orelse return error.InvalidObjectType,
        .tag = tag_tag orelse return error.InvalidTagName,
        .tagger = tagger orelse return error.InvalidTagger,
        .message = message,
    };
}

// TODO writeTag

pub const Tag = struct {
    allocator: mem.Allocator,
    object_name: [20]u8,
    type: ObjectType,
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
        try out_stream.print("Tag{{ object_name: {s}, type: {s}, tag: {s}, tagger: {}, message: \"{s}\" }}", .{ std.fmt.fmtSliceHexLower(&self.object_name), @tagName(self.type), self.tag, self.tagger, self.message });
    }
};
