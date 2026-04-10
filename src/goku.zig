pub fn init(args: cli.Command.Init) !void {
    var threaded_io: std.Io.Threaded = .init(std.heap.page_allocator, .{});
    defer threaded_io.deinit();
    const fs_io = threaded_io.io();

    var site_root_buf: [fs.max_path_bytes]u8 = undefined;
    var cwd_buf: [fs.max_path_bytes]u8 = undefined;
    const cwd = cwd_buf[0..try process.currentPath(fs_io, &cwd_buf)];
    const site_root = switch (args.site_root) {
        .relative => |rel_path| try std.fmt.bufPrint(&site_root_buf, "{s}/{s}", .{ cwd, rel_path }),
        .absolute => |abs_path| abs_path,
    };

    var dir = try std.Io.Dir.cwd().createDirPathOpen(fs_io, site_root, .{});
    defer dir.close(fs_io);

    try scaffold.check(&dir, fs_io);
    try scaffold.write(&dir, fs_io);

    log.info("Site scaffolded at ({s}).", .{site_root});
}

pub fn build(unlimited_allocator: mem.Allocator, args: cli.Command.Build) !void {
    var threaded_io: std.Io.Threaded = .init(unlimited_allocator, .{});
    defer threaded_io.deinit();
    const fs_io = threaded_io.io();

    var site_root_buf: [fs.max_path_bytes]u8 = undefined;
    var cwd_buf: [fs.max_path_bytes]u8 = undefined;
    const cwd = cwd_buf[0..try process.currentPath(fs_io, &cwd_buf)];
    const site_root = switch (args.site_root) {
        .relative => |rel_path| try std.fmt.bufPrint(&site_root_buf, "{s}/{s}", .{ cwd, rel_path }),
        .absolute => |abs_path| abs_path,
    };

    var db: Database = try .init(unlimited_allocator);
    defer db.deinit();

    try storage.Page.init(&db);
    try storage.Template.init(&db);
    try storage.Component.init(&db);

    try indexSite(unlimited_allocator, site_root, &db);

    var site: Site = try .init(unlimited_allocator, &db, site_root, args.url_prefix, args.theme);
    defer site.deinit();

    var out_dir = if (fs.path.isAbsolute(args.out_dir))
        try std.Io.Dir.openDirAbsolute(fs_io, args.out_dir, .{})
    else
        try std.Io.Dir.cwd().createDirPathOpen(fs_io, args.out_dir, .{});
    defer out_dir.close(fs_io);

    try site.write(.sitemap, out_dir, fs_io);
    try site.write(.assets, out_dir, fs_io);
    try site.write(.pages, out_dir, fs_io);
    try site.write(.component_assets, out_dir, fs_io);

    // const assets_dir = try root_dir.openDir("assets");
    // const partials_dir = try root_dir.openDir("partials");
    // const themes_dir = try root_dir.openDir("themes");
}

pub fn preview(unlimited_allocator: mem.Allocator, args: cli.Command.Preview) !void {
    _ = unlimited_allocator;
    _ = args;
    return error.PreviewUnavailable;
}

fn indexSite(allocator: mem.Allocator, site_root: []const u8, db: *Database) !void {
    try indexPages(allocator, site_root, db);
    try indexTemplates(site_root, db);
    try indexComponents(site_root, db);
}

fn readAbsoluteFileAlloc(allocator: mem.Allocator, fs_io: std.Io, filepath: []const u8) ![]const u8 {
    var file = try std.Io.Dir.openFileAbsolute(fs_io, filepath, .{});
    defer file.close(fs_io);

    const stat = try file.stat(fs_io);
    if (stat.size > std.math.maxInt(usize)) return error.FileTooBig;

    var reader_buffer: [4096]u8 = undefined;
    var reader = file.reader(fs_io, &reader_buffer);
    return try reader.interface.readAlloc(allocator, @intCast(stat.size));
}

fn indexPages(unlimited_allocator: mem.Allocator, site_root: []const u8, db: *Database) !void {
    var page_count: u32 = 0;
    var threaded_io: std.Io.Threaded = .init(unlimited_allocator, .{});
    defer threaded_io.deinit();
    const fs_io = threaded_io.io();

    var page_it = filesystem.walker(site_root, "pages");
    defer page_it.deinit();
    while (page_it.next() catch |err| switch (err) {
        error.CannotOpenDirectory => {
            log.err("Cannot open pages dir at {s}/{s}.", .{ page_it.root, page_it.subpath });
            log.err("Suggestion: Create the directory {s}/{s}.", .{ page_it.root, page_it.subpath });
            return error.CannotOpenPagesDirectory;
        },
        else => return err,
    }) |entry| {
        if (entry.kind != .file) continue;

        var filepath_buf: [fs.max_path_bytes]u8 = undefined;
        const filepath = try entry.realpath(&filepath_buf);

        var file = try std.Io.Dir.openFileAbsolute(fs_io, filepath, .{});
        defer file.close(fs_io);

        const length = (try file.stat(fs_io)).size;

        // alice.txt is 148.57kb. I doubt I'll write a single markdown file
        // longer than the entire Alice's Adventures in Wonderland.
        debug.assert(length < size_of_alice_txt);

        const contents = try readAbsoluteFileAlloc(unlimited_allocator, fs_io, filepath);
        defer unlimited_allocator.free(contents);

        const code_fence = page.CodeFence.parse(contents) orelse {
            log.err("Malformed page in source file: {s}", .{filepath});
            return error.MissingFrontmatter;
        };

        const data = page.Data.fromYamlString(unlimited_allocator, code_fence.within, null) catch |err| {
            switch (err) {
                error.MissingSlug => {
                    log.err("Page is missing required, non-empty frontmatter parameter: slug (source file: {s})", .{filepath});
                },
                error.MissingTitle => {
                    log.err("Page is missing required, non-empty frontmatter parameter: title (source file: {s})", .{filepath});
                },
                error.MissingTemplate => {
                    log.err("Page is missing required, non-empty frontmatter parameter: template (source file: {s})", .{filepath});
                },
                else => {},
            }

            return err;
        };
        defer data.deinit(unlimited_allocator);

        try storage.Page.insert(
            db,
            .{
                .slug = data.slug,
                .title = data.title orelse "(missing title)",
                .filepath = filepath,
                .template = data.template.?,
                .collection = data.collection orelse "",
                .date = data.date,
            },
        );

        page_count += 1;
    }

    log.info("Page Count: {d}", .{page_count});
}

fn indexTemplates(site_root: []const u8, db: *Database) !void {
    var template_count: u32 = 0;
    var threaded_io: std.Io.Threaded = .init(std.heap.page_allocator, .{});
    defer threaded_io.deinit();
    const fs_io = threaded_io.io();

    var template_it = filesystem.walker(site_root, "templates");
    defer template_it.deinit();
    while (template_it.next() catch |err| switch (err) {
        error.CannotOpenDirectory => {
            log.err("Cannot open templates dir at {s}/{s}.", .{ template_it.root, template_it.subpath });
            log.err("Suggestion: Create the directory {s}/{s}.", .{ template_it.root, template_it.subpath });
            return error.CannotOpenTemplatesDirectory;
        },
        else => return err,
    }) |entry| {
        if (entry.kind != .file) continue;

        var filepath_buf: [fs.max_path_bytes]u8 = undefined;
        const filepath = try entry.realpath(&filepath_buf);

        var file = try std.Io.Dir.openFileAbsolute(fs_io, filepath, .{});
        defer file.close(fs_io);

        const length = (try file.stat(fs_io)).size;

        // I don't think it makes sense to have an empty template file, right?
        if (length == 0) {
            log.err("Template file cannot be empty. (template path: {s})", .{entry.subpath});
            return error.EmptyTemplate;
        }

        try storage.Template.insert(
            db,
            .{ .filepath = filepath },
        );

        template_count += 1;
    }

    log.info("Template Count: {d}", .{template_count});
}

fn indexComponents(site_root: []const u8, db: *Database) !void {
    var component_count: u32 = 0;

    var component_it = filesystem.walker(site_root, "components");
    defer component_it.deinit();
    while (component_it.next() catch |err| switch (err) {
        error.CannotOpenDirectory => {
            log.err("Cannot open components dir at {s}/{s}.", .{ component_it.root, component_it.subpath });
            return error.CannotOpenComponentsDirectory;
        },
        else => return err,
    }) |entry| {
        if (entry.kind != .file) continue;

        var filepath_buf: [fs.max_path_bytes]u8 = undefined;
        const filepath = try entry.realpath(&filepath_buf);

        try storage.Component.insert(
            db,
            .{
                .name = entry.subpath,
                .filepath = filepath,
            },
        );

        component_count += 1;
    }

    log.info("Component Count: {d}", .{component_count});
}

const std = @import("std");
const process = std.process;
const mem = std.mem;
const cli = @import("Cli.zig");
const Database = @import("Database.zig");
const storage = @import("storage.zig");
const filesystem = @import("source/filesystem.zig");
const log = std.log.scoped(.goku);
const debug = std.debug;
const fs = std.fs;
const page = @import("page.zig");
const heap = std.heap;
const scaffold = @import("scaffold.zig");
const Site = @import("Site.zig");

const size_of_alice_txt = 1189000;
