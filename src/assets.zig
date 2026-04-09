const fs = std.fs;
const heap = std.heap;
const mem = std.mem;
const std = @import("std");
const filesystem = @import("source/filesystem.zig");
const testing = std.testing;

pub const Manifest = struct {
    arena: heap.ArenaAllocator,
    map: std.StringArrayHashMapUnmanaged([]const u8),

    pub fn init(allocator: mem.Allocator) Manifest {
        return .{
            .arena = heap.ArenaAllocator.init(allocator),
            .map = .empty,
        };
    }

    pub fn deinit(self: *Manifest) void {
        self.map.deinit(self.arena.allocator());
        self.arena.deinit();
        self.* = undefined;
    }

    pub fn get(self: *const Manifest, path: []const u8) ?[]const u8 {
        return self.map.get(path);
    }

    pub fn processSiteAssets(self: *Manifest, site_root: []const u8, out_dir: fs.Dir) !void {
        var root_dir = try fs.openDirAbsolute(site_root, .{});
        defer root_dir.close();

        _ = root_dir.access("assets", .{}) catch |err| switch (err) {
            error.FileNotFound => return,
            else => return err,
        };

        const allocator = self.arena.allocator();
        const assets_root = try fs.path.join(allocator, &.{ site_root, "assets" });

        var walker = filesystem.walker(site_root, "assets");
        while (try walker.next()) |entry| {
            const source_abs = try entry.realpath(try allocator.alloc(u8, fs.max_path_bytes));
            const rel = try fs.path.relative(allocator, assets_root, source_abs);
            const contents = blk: {
                var file = try entry.openFile();
                defer file.close();
                break :blk try file.readToEndAlloc(allocator, std.math.maxInt(usize));
            };

            const hashed_rel = try hashedRelativePath(allocator, rel, contents);
            try writeAsset(out_dir, hashed_rel, contents);
            try self.map.put(allocator, try allocator.dupe(u8, rel), hashed_rel);
        }
    }

    fn writeAsset(out_dir: fs.Dir, relative_path: []const u8, contents: []const u8) !void {
        if (fs.path.dirname(relative_path)) |parent| {
            var dir = try out_dir.makeOpenPath(parent, .{});
            defer dir.close();

            var file = try dir.createFile(fs.path.basename(relative_path), .{});
            defer file.close();
            try file.writeAll(contents);
            return;
        }

        var file = try out_dir.createFile(relative_path, .{});
        defer file.close();
        try file.writeAll(contents);
    }
};

pub fn hashedRelativePath(allocator: mem.Allocator, rel: []const u8, contents: []const u8) ![]const u8 {
    var digest: [std.crypto.hash.Md5.digest_length]u8 = undefined;
    std.crypto.hash.Md5.hash(contents, &digest, .{});

    var hash_buf: [12]u8 = undefined;
    _ = std.fmt.bufPrint(&hash_buf, "{s}", .{std.fmt.fmtSliceHexLower(digest[0..6])}) catch unreachable;

    const dirname = fs.path.dirname(rel);
    const basename = fs.path.basename(rel);
    const ext = fs.path.extension(basename);
    const stem = basename[0 .. basename.len - ext.len];

    return if (dirname) |parent|
        try fs.path.join(allocator, &.{ "assets", parent, try std.fmt.allocPrint(allocator, "{s}-{s}{s}", .{ stem, hash_buf[0 .. digest[0..6].len * 2], ext }) })
    else
        try fs.path.join(allocator, &.{ "assets", try std.fmt.allocPrint(allocator, "{s}-{s}{s}", .{ stem, hash_buf[0 .. digest[0..6].len * 2], ext }) });
}

test hashedRelativePath {
    const value = try hashedRelativePath(testing.allocator, "images/logo.png", "hello");
    defer testing.allocator.free(value);

    try testing.expect(mem.startsWith(u8, value, "assets/images/logo-"));
    try testing.expect(mem.endsWith(u8, value, ".png"));
}