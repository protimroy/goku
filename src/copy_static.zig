const fs = std.fs;
const heap = std.heap;
const mem = std.mem;
const process = std.process;
const std = @import("std");
pub fn main(init: std.process.Init.Minimal) !void {
    var buf: [1000 + 2 * fs.max_path_bytes]u8 = undefined;
    var fba = heap.FixedBufferAllocator.init(&buf);
    const allocator = fba.allocator();

    var args_it = try process.Args.Iterator.initAllocator(init.args, allocator);
    defer args_it.deinit();

    // Skip executable name.
    _ = args_it.next();

    var static_path: ?[]const u8 = null;
    var out_path: ?[]const u8 = null;

    while (args_it.next()) |arg| {
        if (mem.eql(u8, "-from", arg)) {
            static_path = try allocator.dupe(u8, args_it.next() orelse return error.InvalidArguments);
        } else if (mem.eql(u8, "-to", arg)) {
            out_path = try allocator.dupe(u8, args_it.next() orelse return error.InvalidArguments);
        }
    }

    if (static_path == null) return error.MissingStaticPath;
    if (out_path == null) return error.MissingOutPath;

    try copyDirContents(static_path.?, out_path.?);
}

fn copyDirContents(from_path: []const u8, to_path: []const u8) !void {
    var threaded_io: std.Io.Threaded = .init(std.heap.page_allocator, .{});
    defer threaded_io.deinit();
    const fs_io = threaded_io.io();

    var dir = try std.Io.Dir.cwd().openDir(fs_io, from_path, .{ .iterate = true });
    defer dir.close(fs_io);

    var out_dir = try std.Io.Dir.cwd().createDirPathOpen(fs_io, to_path, .{});
    defer out_dir.close(fs_io);

    try copyDirContentsHandle(dir, out_dir, fs_io);
}

/// Caller owns the dir handles.
/// This function will close any new handles it opens.
/// Calls itself recursively to handle copying nested dirs.
fn copyDirContentsHandle(from_dir: std.Io.Dir, to_dir: std.Io.Dir, fs_io: std.Io) !void {
    var it = from_dir.iterate();
    while (try it.next(fs_io)) |entry| {
        switch (entry.kind) {
            .file => {
                try from_dir.copyFile(entry.name, to_dir, entry.name, fs_io, .{});
            },
            .directory => {
                var dir = try from_dir.openDir(fs_io, entry.name, .{ .iterate = true });
                defer dir.close(fs_io);
                var out_dir = try to_dir.createDirPathOpen(fs_io, entry.name, .{});
                defer out_dir.close(fs_io);

                try copyDirContentsHandle(dir, out_dir, fs_io);
            },
            else => return error.CantHandleKind,
        }
    }
}
