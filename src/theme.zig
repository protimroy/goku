const c = @import("c");
const heap = std.heap;
const mem = std.mem;
const std = @import("std");
const testing = std.testing;

pub const Theme = struct {
    name: []const u8,
    styles: [][]const u8,
    scripts: [][]const u8,
};

pub const Registry = struct {
    arena: heap.ArenaAllocator,
    map: std.StringArrayHashMapUnmanaged(Theme),
    default_name: ?[]const u8,

    pub fn init(allocator: mem.Allocator) Registry {
        return .{
            .arena = heap.ArenaAllocator.init(allocator),
            .map = .empty,
            .default_name = null,
        };
    }

    pub fn deinit(self: *Registry) void {
        self.map.deinit(self.arena.allocator());
        self.arena.deinit();
        self.* = undefined;
    }

    pub fn loadSiteThemes(self: *Registry, site_root: []const u8, preferred_name: ?[]const u8) !void {
        var threaded_io: std.Io.Threaded = .init(self.arena.allocator(), .{});
        defer threaded_io.deinit();
        const fs_io = threaded_io.io();

        var root_dir = try std.Io.Dir.openDirAbsolute(fs_io, site_root, .{ .iterate = true });
        defer root_dir.close(fs_io);

        var themes_dir = root_dir.openDir(fs_io, "themes", .{ .iterate = true }) catch |err| switch (err) {
            error.FileNotFound => return,
            else => return err,
        };
        defer themes_dir.close(fs_io);

        var it = themes_dir.iterate();
        while (try it.next(fs_io)) |entry| {
            if (entry.kind != .directory) continue;

            const theme_name = try self.arena.allocator().dupe(u8, entry.name);
            const theme = try loadThemeDirectory(self.arena.allocator(), themes_dir, fs_io, entry.name, theme_name);
            try self.map.put(self.arena.allocator(), theme.name, theme);

            if (self.default_name == null and mem.eql(u8, theme.name, "default")) {
                self.default_name = theme.name;
            }
        }

        if (preferred_name) |name| {
            if (self.map.contains(name)) {
                self.default_name = self.map.getKey(name).?;
            }
        }
    }

    pub fn resolve(self: *const Registry, preferred_name: ?[]const u8) ?*const Theme {
        if (preferred_name) |name| {
            if (self.map.getPtr(name)) |theme| return theme;
        }

        if (self.default_name) |name| {
            if (self.map.getPtr(name)) |theme| return theme;
        }

        return null;
    }

    fn loadThemeDirectory(allocator: mem.Allocator, themes_dir: std.Io.Dir, fs_io: std.Io, dir_name: []const u8, fallback_name: []const u8) !Theme {
        var dir = try themes_dir.openDir(fs_io, dir_name, .{});
        defer dir.close(fs_io);

        var file = dir.openFile(fs_io, "theme.yaml", .{}) catch |err| switch (err) {
            error.FileNotFound => {
                return .{
                    .name = fallback_name,
                    .styles = &.{},
                    .scripts = &.{},
                };
            },
            else => return err,
        };
        defer file.close(fs_io);

        var reader_buffer: [4096]u8 = undefined;
        var reader = file.reader(fs_io, &reader_buffer);
        const theme_file = try reader.interface.allocRemaining(allocator, .limited(std.math.maxInt(usize)));

        return try fromYamlString(allocator, theme_file, fallback_name);
    }
};

pub fn fromYamlString(allocator: mem.Allocator, data: []const u8, fallback_name: []const u8) !Theme {
    var parser: c.yaml_parser_t = undefined;
    const parser_ptr: [*c]c.yaml_parser_t = &parser;

    if (c.yaml_parser_initialize(parser_ptr) == 0) {
        return error.YamlParserInit;
    }
    defer c.yaml_parser_delete(parser_ptr);

    c.yaml_parser_set_input_string(parser_ptr, @ptrCast(data), data.len);

    var ev: c.yaml_event_t = undefined;
    const ev_ptr: [*c]c.yaml_event_t = &ev;

    var name: ?[]const u8 = null;
    var styles = std.array_list.Managed([]const u8).init(allocator);
    errdefer styles.deinit();
    var scripts = std.array_list.Managed([]const u8).init(allocator);
    errdefer scripts.deinit();

    var done = false;
    var key_state: enum {
        key,
        name,
        styles,
        scripts,
        discard,
    } = .key;

    while (!done) {
        if (c.yaml_parser_parse(parser_ptr, ev_ptr) == 0) {
            return error.Parse;
        }

        switch (ev.type) {
            c.YAML_SCALAR_EVENT => {
                const scalar = ev.data.scalar;
                const value = scalar.value[0..scalar.length];

                switch (key_state) {
                    .key => {
                        if (mem.eql(u8, value, "name")) {
                            key_state = .name;
                        } else if (mem.eql(u8, value, "styles")) {
                            key_state = .styles;
                        } else if (mem.eql(u8, value, "scripts")) {
                            key_state = .scripts;
                        } else {
                            key_state = .discard;
                        }
                    },
                    .name => {
                        name = try allocator.dupe(u8, value);
                        key_state = .key;
                    },
                    .styles => {
                        try styles.append(try allocator.dupe(u8, value));
                    },
                    .scripts => {
                        try scripts.append(try allocator.dupe(u8, value));
                    },
                    .discard => {
                        key_state = .key;
                    },
                }
            },
            c.YAML_SEQUENCE_END_EVENT => {
                if (key_state == .styles or key_state == .scripts) {
                    key_state = .key;
                }
            },
            c.YAML_MAPPING_END_EVENT => {
                key_state = .key;
            },
            else => {},
        }

        done = (ev.type == c.YAML_STREAM_END_EVENT);
        c.yaml_event_delete(ev_ptr);
    }

    return .{
        .name = name orelse fallback_name,
        .styles = try styles.toOwnedSlice(),
        .scripts = try scripts.toOwnedSlice(),
    };
}

test fromYamlString {
    const yaml =
        \\name: default
        \\styles:
        \\  - bulma.css
        \\  - assets/site.css
        \\scripts:
        \\  - htmx.js
    ;

    const theme = try fromYamlString(testing.allocator, yaml, "fallback");
    defer {
        testing.allocator.free(theme.name);
        for (theme.styles) |style| testing.allocator.free(style);
        testing.allocator.free(theme.styles);
        for (theme.scripts) |script| testing.allocator.free(script);
        testing.allocator.free(theme.scripts);
    }

    try testing.expectEqualStrings("default", theme.name);
    try testing.expectEqual(@as(usize, 2), theme.styles.len);
    try testing.expectEqual(@as(usize, 1), theme.scripts.len);
}