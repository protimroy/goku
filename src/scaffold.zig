const fs = @import("std").fs;
const std = @import("std");

pub fn check(dir: *std.Io.Dir, fs_io: std.Io) !void {
    if (try exists(dir, fs_io, ".gitignore") or
        try exists(dir, fs_io, "assets") or
        try exists(dir, fs_io, "themes") or
        try exists(dir, fs_io, "pages") or
        try exists(dir, fs_io, "templates") or
        try exists(dir, fs_io, "components") or
        try exists(dir, fs_io, "build"))
    {
        return error.DirectoryNotEmpty;
    }
}

pub fn write(dir: *std.Io.Dir, fs_io: std.Io) !void {
    inline for (&.{
        ".gitignore",
    }) |sub_path| {
        try dir.writeFile(fs_io, .{
            .sub_path = sub_path,
            .data = @embedFile("scaffold/site_template/" ++ sub_path),
        });
    }

    {
        var pages_dir = try dir.createDirPathOpen(fs_io, "pages", .{});
        defer pages_dir.close(fs_io);

        try pages_dir.writeFile(fs_io, .{
            .sub_path = "index.md",
            .data = @embedFile("scaffold/site_template/pages/index.md"),
        });
    }

    {
        var templates_dir = try dir.createDirPathOpen(fs_io, "templates", .{});
        defer templates_dir.close(fs_io);

        try templates_dir.writeFile(fs_io, .{
            .sub_path = "page.html",
            .data = @embedFile("scaffold/site_template/templates/page.html"),
        });
    }

    {
        var components_dir = try dir.createDirPathOpen(fs_io, "components", .{});
        defer components_dir.close(fs_io);

        try components_dir.writeFile(fs_io, .{
            .sub_path = "button.js",
            .data = @embedFile("scaffold/site_template/components/button.js"),
        });
    }

    {
        var themes_dir = try dir.createDirPathOpen(fs_io, "themes/default", .{});
        defer themes_dir.close(fs_io);

        try themes_dir.writeFile(fs_io, .{
            .sub_path = "theme.yaml",
            .data = @embedFile("scaffold/site_template/themes/default/theme.yaml"),
        });
    }

    try dir.createDir(fs_io, "assets", .default_dir);

    try dir.createDir(fs_io, "build", .default_dir);
}

fn exists(dir: *std.Io.Dir, fs_io: std.Io, sub_path: []const u8) !bool {
    _ = dir.statFile(fs_io, sub_path, .{}) catch |err| switch (err) {
        error.FileNotFound => return false,
        else => return err,
    };

    return true;
}
