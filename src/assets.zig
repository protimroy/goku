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

    pub fn processSiteAssets(self: *Manifest, site_root: []const u8, out_dir: std.Io.Dir, fs_io: std.Io) !void {
        const allocator = self.arena.allocator();
        const assets_root = try fs.path.join(allocator, &.{ site_root, "assets" });

        var walker = filesystem.walker(site_root, "assets");
        defer walker.deinit();
        while (walker.next() catch |err| switch (err) {
            error.CannotOpenDirectory => return,
            else => return err,
        }) |entry| {
            var source_path_buf: [fs.max_path_bytes]u8 = undefined;
            const source_abs = try entry.realpath(&source_path_buf);
            const rel = try fs.path.relative(allocator, "", null, assets_root, source_abs);
            const contents = blk: {
                var file = try std.Io.Dir.openFileAbsolute(fs_io, source_abs, .{});
                defer file.close(fs_io);
                var reader_buffer: [4096]u8 = undefined;
                var reader = file.reader(fs_io, &reader_buffer);
                break :blk try reader.interface.allocRemaining(allocator, .limited(std.math.maxInt(usize)));
            };

            const hashed_rel = try hashedRelativePath(allocator, rel, contents);
            try writeAsset(out_dir, fs_io, hashed_rel, contents);
            try self.map.put(allocator, try allocator.dupe(u8, rel), hashed_rel);
        }
    }

    fn writeAsset(out_dir: std.Io.Dir, fs_io: std.Io, relative_path: []const u8, contents: []const u8) !void {
        if (fs.path.dirname(relative_path)) |parent| {
            var dir = try out_dir.createDirPathOpen(fs_io, parent, .{});
            defer dir.close(fs_io);
            try dir.writeFile(fs_io, .{
                .sub_path = fs.path.basename(relative_path),
                .data = contents,
            });
            return;
        }

        try out_dir.writeFile(fs_io, .{
            .sub_path = relative_path,
            .data = contents,
        });
    }
};

pub fn hashedRelativePath(allocator: mem.Allocator, rel: []const u8, contents: []const u8) ![]const u8 {
    var digest: [std.crypto.hash.Md5.digest_length]u8 = undefined;
    std.crypto.hash.Md5.hash(contents, &digest, .{});

    const hash_buf = std.fmt.bytesToHex(digest[0..6], .lower);

    const dirname = fs.path.dirname(rel);
    const basename = fs.path.basename(rel);
    const ext = fs.path.extension(basename);
    const stem = basename[0 .. basename.len - ext.len];
    const hashed_basename = try std.fmt.allocPrint(allocator, "{s}-{s}{s}", .{ stem, hash_buf[0..], ext });
    defer allocator.free(hashed_basename);

    return if (dirname) |parent|
        try fs.path.join(allocator, &.{ "assets", parent, hashed_basename })
    else
        try fs.path.join(allocator, &.{ "assets", hashed_basename });
}

test hashedRelativePath {
    const value = try hashedRelativePath(testing.allocator, "images/logo.png", "hello");
    defer testing.allocator.free(value);

    try testing.expect(mem.startsWith(u8, value, "assets/images/logo-"));
    try testing.expect(mem.endsWith(u8, value, ".png"));
}