const debug = std.debug;
const fs = std.fs;
const heap = std.heap;
const mem = std.mem;
const std = @import("std");
const testing = std.testing;
const Io = std.Io;

pub fn walker(root: []const u8, subpath: []const u8) WalkerType(.{ .max_dir_handles = 1024 }) {
    return .{ .root = root, .subpath = subpath };
}

pub const WalkerConfig = struct {
    max_dir_handles: comptime_int,
};

// Creates a zero-allocation filesystem walker, to iterate over all files
// in a directory, recursively.
pub fn WalkerType(comptime config: WalkerConfig) type {
    _ = config;

    return struct {
        root: []const u8,
        subpath: []const u8,

        done: bool = false,
        threaded_io: ?Io.Threaded = null,
        root_dir: ?Io.Dir = null,
        walk_root: ?Io.Dir = null,
        dir_walker: ?Io.Dir.Walker = null,
        base_path: ?[]u8 = null,

        const Self = @This();

        pub const Entry = struct {
            base_path: []const u8,
            subpath: []const u8,
            kind: Io.File.Kind,

            pub fn realpath(self: Entry, buf: []u8) ![]const u8 {
                if (self.subpath.len == 0) {
                    return try std.fmt.bufPrint(buf, "{s}", .{self.base_path});
                }
                return try std.fmt.bufPrint(buf, "{s}/{s}", .{ self.base_path, self.subpath });
            }
        };

        fn io(self: *Self) Io {
            return self.threaded_io.?.io();
        }

        pub fn deinit(self: *Self) void {
            if (self.dir_walker) |*walker_impl| walker_impl.deinit();

            if (self.threaded_io) |*threaded_io| {
                const fs_io = threaded_io.io();
                if (self.walk_root) |dir| dir.close(fs_io);
                if (self.root_dir) |dir| dir.close(fs_io);
                threaded_io.deinit();
            }

            if (self.base_path) |path| heap.page_allocator.free(path);
        }

        pub fn next(self: *Self) !?Entry {
            if (self.done) return null;

            try self.ensureWalker();

            const fs_io = self.io();
            if (try self.dir_walker.?.next(fs_io)) |entry| {
                return .{
                    .base_path = self.base_path.?,
                    .subpath = entry.path,
                    .kind = entry.kind,
                };
            }

            self.done = true;
            return null;
        }

        fn ensureWalker(self: *Self) !void {
            debug.assert(!self.done);
            if (self.dir_walker != null) return;

            self.threaded_io = .init(heap.page_allocator, .{});
            errdefer {
                self.threaded_io.?.deinit();
                self.threaded_io = null;
            }

            const fs_io = self.io();
            const root_dir = if (fs.path.isAbsolute(self.root))
                Io.Dir.openDirAbsolute(fs_io, self.root, .{}) catch return error.CannotOpenDirectory
            else
                Io.Dir.cwd().openDir(fs_io, self.root, .{}) catch return error.CannotOpenDirectory;
            errdefer root_dir.close(fs_io);

            const walk_root = root_dir.openDir(fs_io, self.subpath, .{ .iterate = true }) catch return error.CannotOpenDirectory;
            errdefer walk_root.close(fs_io);

            self.base_path = try fs.path.join(heap.page_allocator, &.{ self.root, self.subpath });
            self.root_dir = root_dir;
            self.walk_root = walk_root;
            self.dir_walker = try walk_root.walk(heap.page_allocator);
        }

        test next {
            var instance: Self = .{ .root = ".", .subpath = ".", .done = true };
            defer instance.deinit();

            try testing.expectEqual(null, try instance.next());
        }

        test ensureWalker {
            var instance: Self = .{ .root = ".", .subpath = "." };
            defer instance.deinit();

            try testing.expectEqual(null, instance.dir_walker);

            try instance.ensureWalker();

            try testing.expect(instance.dir_walker != null);
        }
    };
}

test {
    testing.refAllDecls(@This());
}
