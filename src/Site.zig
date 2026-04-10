const assets = @import("assets.zig");
const BatchAllocator = @import("BatchAllocator.zig");
const bulma = @import("bulma");
const htmx = @import("htmx");
const debug = std.debug;
const fs = std.fs;
const heap = std.heap;
const io = std.io;
const log = std.log.scoped(.site);
const math = std.math;
const mem = std.mem;
const mustache = @import("mustache.zig");
const page = @import("page.zig");
const std = @import("std");
const storage = @import("storage.zig");
const testing = std.testing;
const Database = @import("Database.zig");
const markdown = @import("markdown.zig");
const theme = @import("theme.zig");

// TODO remove this property
// Site root is only used for constructing an absolute path to
// a template file. The db should be used for looking up templates
// instead.
site_root: []const u8,
url_prefix: ?[]const u8,
allocator: mem.Allocator,
db: *Database,
component_assets: *ComponentAssets,
selected_theme_name: ?[]const u8,
themes: theme.Registry,
asset_manifest: assets.Manifest,

pub const ComponentAssets = struct {
    arena: *heap.ArenaAllocator,
    style_map: std.StringArrayHashMapUnmanaged([]const u8),
    script_map: std.StringArrayHashMapUnmanaged([]const u8),

    pub fn init(allocator: mem.Allocator, db: *Database) !ComponentAssets {
        const arena = try allocator.create(heap.ArenaAllocator);
        arena.* = .init(allocator);
        _ = db;

        return .{
            .arena = arena,
            .style_map = .empty,
            .script_map = .empty,
        };
    }

    pub fn deinit(self: *ComponentAssets) void {
        const allocator = self.arena.*.child_allocator;
        self.arena.deinit();
        allocator.destroy(self.arena);
        self.* = undefined;
    }

    fn getNumComponents(db: *Database) !usize {
        var stmt = try db.db.prepare("SELECT count(*) FROM components;");
        defer stmt.deinit();
    }
};

const Site = @This();

pub const Pagination = struct {
    collection: []const u8,
    current_page: u32,
    per_page: u32,
    total_items: u32,
    base_slug: []const u8,

    pub fn totalPages(self: Pagination) u32 {
        return @max(1, std.math.divCeil(u32, self.total_items, self.per_page) catch 1);
    }
};

const HtmlSitemap = struct {
    // HTML HtmlSitemap looks like this:
    // <nav><ul>
    // <li><a href="{slug}">{text}</a></li>
    // <li><a href="{slug}">{text}</a></li>
    // ...
    // </ul></nav>
    pub const preamble =
        \\<nav><ul>
    ;
    pub const postamble =
        \\</ul></nav>
    ;

    /// It's ridiculous for a URI to exceed this number of bytes
    pub const http_uri_len_max = 2000;

    /// I went to a news website's front page and found that the longest
    /// article title was 128 bytes long. That seems like it could be
    /// a reasonable limit, but I'd rather just double it out of the gate
    /// and set the max length to 256.
    pub const url_title_len_max = 256;

    pub const item_surround = "<li><a href=\"\"></a></li>";
    pub const item_size_max = item_surround.len + http_uri_len_max + url_title_len_max;

    pub fn write(site: Site, writer: anytype) !void {
        try writer.writeAll(preamble);

        // iterate over pages in site
        {
            var it = try storage.Page.iterate(
                struct { slug: []const u8, title: []const u8 },
                site.allocator,
                site.db,
            );
            defer it.deinit();

            while (try it.next()) |entry| {
                var buffer: [HtmlSitemap.item_size_max]u8 = undefined;
                var fba = heap.FixedBufferAllocator.init(
                    &buffer,
                );
                var buf = std.ArrayList(u8).init(
                    fba.allocator(),
                );

                try buf.writer().print(
                    \\<li><a href="{s}{s}">{s}</a></li>
                ,
                    .{ site.url_prefix orelse "", entry.slug, entry.title },
                );

                try writer.writeAll(buf.items);
            }
        }

        try writer.writeAll(postamble);
    }
};

const IndexedPage = struct {
    slug: []const u8,
    title: []const u8,
    date: ?[]const u8,
};

fn writeEscapedXml(writer: anytype, input: []const u8) !void {
    for (input) |char| {
        switch (char) {
            '&' => try writer.writeAll("&amp;"),
            '<' => try writer.writeAll("&lt;"),
            '>' => try writer.writeAll("&gt;"),
            '\'' => try writer.writeAll("&apos;"),
            '"' => try writer.writeAll("&quot;"),
            else => try writer.writeByte(char),
        }
    }
}

fn writePageUrl(site: Site, writer: anytype, slug: []const u8) !void {
    try writer.writeAll(site.url_prefix orelse "");
    try writer.writeAll(slug);
}

fn writeXmlSitemap(site: Site, writer: anytype) !void {
    var arena = heap.ArenaAllocator.init(site.allocator);
    defer arena.deinit();

    try writer.writeAll("<?xml version=\"1.0\" encoding=\"UTF-8\"?>");
    try writer.writeAll("<urlset xmlns=\"http://www.sitemaps.org/schemas/sitemap/0.9\">");

    var stmt = try site.db.db.prepare(
        \\SELECT slug, title, date
        \\FROM pages
        \\ORDER BY date DESC, title ASC
    );
    defer stmt.deinit();

    var it = try stmt.iterator(IndexedPage, .{});
    while (try it.nextAlloc(arena.allocator(), .{})) |entry| {
        try writer.writeAll("<url><loc>");
        try writePageUrl(site, writer, entry.slug);
        try writer.writeAll("</loc>");
        if (entry.date) |date| {
            try writer.writeAll("<lastmod>");
            try writeEscapedXml(writer, date);
            try writer.writeAll("</lastmod>");
        }
        try writer.writeAll("</url>");
    }

    try writer.writeAll("</urlset>");
}

fn writeAtomFeed(site: Site, writer: anytype) !void {
    var arena = heap.ArenaAllocator.init(site.allocator);
    defer arena.deinit();

    try writer.writeAll("<?xml version=\"1.0\" encoding=\"utf-8\"?>");
    try writer.writeAll("<feed xmlns=\"http://www.w3.org/2005/Atom\">");
    try writer.writeAll("<title>");
    try writeEscapedXml(writer, fs.path.basename(site.site_root));
    try writer.writeAll("</title><id>");
    try writeEscapedXml(writer, site.url_prefix orelse "/");
    try writer.writeAll("</id>");

    var stmt = try site.db.db.prepare(
        \\SELECT slug, title, date
        \\FROM pages
        \\ORDER BY date DESC, title ASC
    );
    defer stmt.deinit();

    var it = try stmt.iterator(IndexedPage, .{});
    var wrote_updated = false;
    while (try it.nextAlloc(arena.allocator(), .{})) |entry| {
        if (!wrote_updated) {
            try writer.writeAll("<updated>");
            try writeEscapedXml(writer, entry.date orelse "1970-01-01");
            try writer.writeAll("</updated>");
            wrote_updated = true;
        }

        try writer.writeAll("<entry><title>");
        try writeEscapedXml(writer, entry.title);
        try writer.writeAll("</title><id>");
        try writePageUrl(site, writer, entry.slug);
        try writer.writeAll("</id><link href=\"");
        try writePageUrl(site, writer, entry.slug);
        try writer.writeAll("\" />");
        if (entry.date) |date| {
            try writer.writeAll("<updated>");
            try writeEscapedXml(writer, date);
            try writer.writeAll("</updated>");
        }
        try writer.writeAll("</entry>");
    }

    if (!wrote_updated) {
        try writer.writeAll("<updated>1970-01-01</updated>");
    }

    try writer.writeAll("</feed>");
}

fn writeRssFeed(site: Site, writer: anytype) !void {
    var arena = heap.ArenaAllocator.init(site.allocator);
    defer arena.deinit();

    try writer.writeAll("<?xml version=\"1.0\" encoding=\"UTF-8\"?>");
    try writer.writeAll("<rss version=\"2.0\"><channel><title>");
    try writeEscapedXml(writer, fs.path.basename(site.site_root));
    try writer.writeAll("</title><link>");
    try writeEscapedXml(writer, site.url_prefix orelse "/");
    try writer.writeAll("</link><description>");
    try writeEscapedXml(writer, fs.path.basename(site.site_root));
    try writer.writeAll("</description>");

    var stmt = try site.db.db.prepare(
        \\SELECT slug, title, date
        \\FROM pages
        \\ORDER BY date DESC, title ASC
    );
    defer stmt.deinit();

    var it = try stmt.iterator(IndexedPage, .{});
    while (try it.nextAlloc(arena.allocator(), .{})) |entry| {
        try writer.writeAll("<item><title>");
        try writeEscapedXml(writer, entry.title);
        try writer.writeAll("</title><link>");
        try writePageUrl(site, writer, entry.slug);
        try writer.writeAll("</link><guid>");
        try writePageUrl(site, writer, entry.slug);
        try writer.writeAll("</guid>");
        if (entry.date) |date| {
            try writer.writeAll("<pubDate>");
            try writeEscapedXml(writer, date);
            try writer.writeAll("</pubDate>");
        }
        try writer.writeAll("</item>");
    }

    try writer.writeAll("</channel></rss>");
}

const fallback_template =
    "<!-- Missing template in page frontmatter -->{{& content }}";

pub fn init(
    allocator: mem.Allocator,
    database: *Database,
    site_root: []const u8,
    url_prefix: ?[]const u8,
    selected_theme_name: ?[]const u8,
) !Site {
    const component_assets = try allocator.create(ComponentAssets);
    errdefer allocator.destroy(component_assets);
    component_assets.* = try .init(allocator, database);
    errdefer component_assets.deinit();

    var themes = theme.Registry.init(allocator);
    errdefer themes.deinit();
    try themes.loadSiteThemes(site_root, selected_theme_name);

    var asset_manifest = assets.Manifest.init(allocator);
    errdefer asset_manifest.deinit();

    const site: Site = .{
        .allocator = allocator,
        .db = database,
        .site_root = site_root,
        .url_prefix = url_prefix,
        .component_assets = component_assets,
        .selected_theme_name = selected_theme_name,
        .themes = themes,
        .asset_manifest = asset_manifest,
    };

    try site.validate();

    return site;
}

pub fn deinit(self: *Site) void {
    self.component_assets.deinit();
    self.allocator.destroy(self.component_assets);
    self.themes.deinit();
    self.asset_manifest.deinit();
}

fn resolveTheme(self: *const Site, preferred_name: ?[]const u8) ?*const theme.Theme {
    return self.themes.resolve(preferred_name orelse self.selected_theme_name);
}

pub fn validate(self: Site) !void {
    // Find all unique templates in pages
    // Ensure each template exists as an entry in sqlite

    const get_templates = .{
        .stmt =
        \\ SELECT DISTINCT template
        \\ FROM pages
        ,
        .type = struct {
            template: []const u8,
        },
    };

    var get_stmt = try self.db.db.prepare(get_templates.stmt);
    defer get_stmt.deinit();

    var it = try get_stmt.iterator(
        get_templates.type,
        .{},
    );

    var arena = heap.ArenaAllocator.init(self.allocator);
    defer arena.deinit();

    while (try it.nextAlloc(arena.allocator(), .{})) |entry| {
        const get_template = .{
            .stmt =
            \\ SELECT filepath
            \\ FROM templates
            \\ WHERE filepath = ?
            \\ LIMIT 1
            ,
            .type = struct {
                filepath: []const u8,
            },
        };

        var get_template_stmt = try self.db.db.prepare(get_template.stmt);
        defer get_template_stmt.deinit();

        var buf: [fs.max_path_bytes]u8 = undefined;
        var fba = heap.FixedBufferAllocator.init(&buf);
        const filepath = try fs.path.join(fba.allocator(), &.{
            self.site_root,
            "templates",
            entry.template,
        });

        const row = try get_template_stmt.oneAlloc(
            get_template.type,
            arena.allocator(),
            .{},
            .{
                .filepath = filepath,
            },
        );

        if (row == null) {
            log.err("The template ({s}) does not exist.", .{entry.template});
            return error.MissingTemplate;
        }
    }
}

pub fn write(
    self: *Site,
    part: enum { sitemap, assets, pages, component_assets },
    out_dir: fs.Dir,
) !void {
    switch (part) {
        .sitemap => try writeSitemap(self.*, out_dir),
        .assets => try writeAssets(self, out_dir),
        .pages => try writePages(self.*, out_dir),
        .component_assets => try writeComponentAssets(self.*, out_dir),
    }
}

fn writeSitemap(self: Site, out_dir: fs.Dir) !void {
    {
        var file = try out_dir.createFile("_sitemap.html", .{});
        defer file.close();

        var file_buf = io.bufferedWriter(file.writer());
        try HtmlSitemap.write(self, file_buf.writer());
        try file_buf.flush();
    }

    {
        var file = try out_dir.createFile("sitemap.xml", .{});
        defer file.close();

        var file_buf = io.bufferedWriter(file.writer());
        try writeXmlSitemap(self, file_buf.writer());
        try file_buf.flush();
    }

    {
        var file = try out_dir.createFile("atom.xml", .{});
        defer file.close();

        var file_buf = io.bufferedWriter(file.writer());
        try writeAtomFeed(self, file_buf.writer());
        try file_buf.flush();
    }

    {
        var file = try out_dir.createFile("rss.xml", .{});
        defer file.close();

        var file_buf = io.bufferedWriter(file.writer());
        try writeRssFeed(self, file_buf.writer());
        try file_buf.flush();
    }
}

fn writeAssets(self: *Site, out_dir: fs.Dir) !void {
    {
        var file = try out_dir.createFile(
            "bulma.css",
            .{},
        );
        defer file.close();
        try file.writer().writeAll(bulma.min.css);
    }

    {
        var file = try out_dir.createFile(
            "htmx.js",
            .{},
        );
        defer file.close();
        try file.writer().writeAll(htmx.js);
    }

    try self.asset_manifest.processSiteAssets(self.site_root, out_dir);
    try writeThemeAssets(self.*, out_dir);
}

fn writeThemeAssets(self: Site, out_dir: fs.Dir) !void {
    const allocator = self.allocator;

    for (self.themes.map.keys()) |theme_name| {
        const theme_root = try fs.path.join(allocator, &.{ self.site_root, "themes", theme_name });
        defer allocator.free(theme_root);

        const walker_subpath = try std.fmt.allocPrint(allocator, "themes/{s}", .{theme_name});
        defer allocator.free(walker_subpath);

        var walker = @import("source/filesystem.zig").walker(self.site_root, walker_subpath);
        while (walker.next() catch |err| switch (err) {
            error.CannotOpenDirectory => break,
            else => return err,
        }) |entry| {
            var source_path_buf: [fs.max_path_bytes]u8 = undefined;
            const source_abs = try entry.realpath(&source_path_buf);
            const rel = try fs.path.relative(allocator, theme_root, source_abs);
            defer allocator.free(rel);
            if (mem.eql(u8, rel, "theme.yaml")) continue;

            var file = try entry.openFile();
            defer file.close();
            const contents = try file.readToEndAlloc(allocator, std.math.maxInt(usize));
            defer allocator.free(contents);

            const out_rel = try fs.path.join(allocator, &.{ "theme", theme_name, rel });
            defer allocator.free(out_rel);
            try writeOutputFile(out_dir, out_rel, contents);
        }
    }
}

fn writeOutputFile(out_dir: fs.Dir, rel_path: []const u8, contents: []const u8) !void {
    if (fs.path.dirname(rel_path)) |parent| {
        var dir = try out_dir.makeOpenPath(parent, .{});
        defer dir.close();

        var file = try dir.createFile(fs.path.basename(rel_path), .{});
        defer file.close();
        try file.writeAll(contents);
        return;
    }

    var file = try out_dir.createFile(rel_path, .{});
    defer file.close();
    try file.writeAll(contents);
}

fn writePages(self: Site, out_dir: fs.Dir) !void {
    var it = try storage.Page.iterate(
        struct { slug: []const u8, filepath: []const u8 },
        self.allocator,
        self.db,
    );
    defer it.deinit();

    var batch_allocator = BatchAllocator.init(self.allocator);
    defer batch_allocator.deinit();

    while (try it.next()) |entry| {
        defer batch_allocator.flush();

        const page_data = try readPageData(batch_allocator.allocator(), entry.filepath);
        if (page_data.paginate) |per_page| {
            if (page_data.collection) |collection| {
                const total_items = try getCollectionCount(self.db, collection);
                const total_pages = @max(1, std.math.divCeil(u32, total_items, per_page) catch 1);

                var page_number: u32 = 1;
                while (page_number <= total_pages) : (page_number += 1) {
                    try _render(
                        batch_allocator.allocator(),
                        &self,
                        entry.filepath,
                        entry.slug,
                        .wants_content,
                        out_dir,
                        .{
                            .collection = collection,
                            .current_page = page_number,
                            .per_page = per_page,
                            .total_items = total_items,
                            .base_slug = entry.slug,
                        },
                    );
                }
                continue;
            }
        }

        try _render(
            batch_allocator.allocator(),
            &self,
            entry.filepath,
            entry.slug,
            .wants_content,
            out_dir,
            null,
        );
    }
}

fn readPageData(allocator: mem.Allocator, filepath: []const u8) !page.Data {
    var file = try fs.openFileAbsolute(filepath, .{});
    defer file.close();

    const contents = try file.readToEndAlloc(allocator, std.math.maxInt(u32));
    const result = page.CodeFence.parse(contents) orelse return error.MalformedPageFile;

    const p: page.Page = .{
        .markdown = .{
            .frontmatter = result.within,
            .content = result.after,
        },
    };

    return try p.data(allocator);
}

fn getCollectionCount(db: *Database, collection: []const u8) !u32 {
    var stmt = try db.db.prepare(
        \\SELECT count(*) as count
        \\FROM pages
        \\WHERE collection = ?
    );
    defer stmt.deinit();

    const row = try stmt.oneAlloc(
        struct { count: u32 },
        std.heap.page_allocator,
        .{},
        .{ .collection = collection },
    ) orelse return 0;

    return row.count;
}

fn writeComponentAssets(self: Site, out_dir: fs.Dir) !void {
    {
        var css_file = try out_dir.createFile("component.css", .{});
        defer css_file.close();
        const file_writer = css_file.writer();

        log.info("Write component.css", .{});

        if (self.component_assets.style_map.count() > 0) {
            for (self.component_assets.style_map.values()) |chunk| {
                try file_writer.print("{s}", .{chunk});
            }
        }
    }

    {
        var js_file = try out_dir.createFile("component.js", .{});
        defer js_file.close();
        const file_writer = js_file.writer();

        log.info("Write component.js", .{});

        if (self.component_assets.script_map.count() > 0) {
            for (self.component_assets.script_map.values()) |chunk| {
                try file_writer.print(
                    \\;(function() {{
                    \\  'use strict';
                    \\{[script_body]s}
                    \\}}())
                ,
                    .{ .script_body = chunk },
                );
            }
        }
    }
}

/// Assumes that the provided allocator is an arena.
/// Reads the page and its associated template from the filesystem
/// and writes the rendered page to a file in the out_dir.
///
/// May also write to the `component.css` file if the page wrote
/// to a dedicated styles buffer while rendering.
fn _render(
    ally: mem.Allocator,
    site: *const Site,
    filepath: []const u8,
    slug: []const u8,
    wants: DispatchWants,
    out_dir: fs.Dir,
    pagination: ?Pagination,
) !void {
    switch (wants) {
        .wants_raw => unreachable,
        else => {},
    }

    // Read the file contents
    const contents = contents: {
        const in_file = try fs.openFileAbsolute(
            filepath,
            .{},
        );
        defer in_file.close();

        break :contents try in_file.readToEndAlloc(
            ally,
            math.maxInt(u32),
        );
    };

    // Parse the Page metadata
    const result = page.CodeFence.parse(contents) orelse
        return error.MalformedPageFile;

    const p: page.Page = .{
        .markdown = .{
            .frontmatter = result.within,
            .content = result.after,
        },
    };

    const data = try p.data(ally);

    // Create the out file
    const file = file: {
        var filename_buf = std.ArrayList(u8).init(ally);
        defer filename_buf.deinit();

        const effective_slug = if (pagination) |page_ctx|
            try paginationSlug(ally, page_ctx)
        else
            slug;

        // TODO the function accepts slug as an argument but we'll also have
        // the slug after parsing the page metadata out. Is it redundant to
        // accept the slug as a function argument?
        debug.assert(effective_slug.len > 0);
        debug.assert(effective_slug[0] == '/');
        if (effective_slug.len > 1) {
            debug.assert(!mem.endsWith(u8, effective_slug, "/"));
            try filename_buf.appendSlice(effective_slug);
        }
        try filename_buf.appendSlice("/index.html");

        make_parent: {
            if (fs.path.dirname(filename_buf.items)) |parent| {
                debug.assert(parent[0] == '/');
                if (parent.len == 1) break :make_parent;

                var dir = try out_dir.makeOpenPath(
                    parent[1..],
                    .{},
                );
                defer dir.close();
                break :file try dir.createFile(
                    fs.path.basename(filename_buf.items),
                    .{},
                );
            }
        }

        break :file try out_dir.createFile(
            fs.path.basename(filename_buf.items),
            .{},
        );
    };
    defer file.close();

    var html_buffer = io.bufferedWriter(file.writer());

    // Load the template from the filesystem
    const template = template: {
        if (data.template) |t| {
            const template_path = try fs.path.join(
                ally,
                &.{ site.site_root, "templates", t },
            );

            var template_file = try fs.openFileAbsolute(
                template_path,
                .{},
            );
            defer template_file.close();

            const template = try template_file.readToEndAlloc(
                ally,
                math.maxInt(u32),
            );
            break :template template;
        }

        break :template fallback_template;
    };

    try renderPage(
        ally,
        p,
        .{ .bytes = template },
        site.db,
        site.component_assets,
        site.site_root,
        site.url_prefix,
        site.resolveTheme(data.theme),
        &site.asset_manifest,
        pagination,
        wants,
        html_buffer.writer(),
    );

    try html_buffer.flush();
}

// TODO actual needs don't reflect this initial design. Simplify.
pub const TemplateOption = union(enum) {
    this: void,
    bytes: []const u8,
};

pub fn getDispatchSourceFile(site: *Site, arena: mem.Allocator, slug: []const u8) !?[]const u8 {
    var stmt = try site.db.db.prepare(
        \\SELECT filepath FROM pages WHERE slug = ?;
    );
    defer stmt.deinit();

    if (try stmt.oneAlloc(struct { filepath: []const u8 }, arena, .{}, .{ .slug = slug })) |row| {
        return row.filepath;
    }

    return null;
}

const DispatchError = error{ NotFound, DbError, ReadError, RenderError, OOM };
pub const DispatchWants = enum { wants_editor, wants_raw, wants_content };
const DispatchOptions = struct {
    wants: DispatchWants = .wants_content,
};

fn unwrapBibliographyValue(raw: []const u8) []const u8 {
    var value = mem.trim(u8, raw, " \t\r\n");
    while (value.len >= 2) {
        if ((value[0] == '{' and value[value.len - 1] == '}') or (value[0] == '"' and value[value.len - 1] == '"')) {
            value = mem.trim(u8, value[1 .. value.len - 1], " \t\r\n");
            continue;
        }
        break;
    }
    return value;
}

fn normalizeBibliographyText(allocator: mem.Allocator, raw: []const u8) ![]const u8 {
    const value = unwrapBibliographyValue(raw);
    var buf = std.ArrayList(u8).init(allocator);
    errdefer buf.deinit();

    var last_was_space = true;
    for (value) |char| {
        switch (char) {
            '{', '}' => {},
            ' ', '\t', '\r', '\n' => {
                if (!last_was_space and buf.items.len > 0) {
                    try buf.append(' ');
                    last_was_space = true;
                }
            },
            else => {
                try buf.append(char);
                last_was_space = false;
            },
        }
    }

    return try buf.toOwnedSlice();
}

fn normalizeBibtexAuthors(allocator: mem.Allocator, raw: []const u8) ![]const u8 {
    const value = unwrapBibliographyValue(raw);
    var buf = std.ArrayList(u8).init(allocator);
    errdefer buf.deinit();

    var authors = mem.splitSequence(u8, value, " and ");
    var first = true;
    while (authors.next()) |author| {
        const trimmed = mem.trim(u8, author, " \t\r\n");
        if (trimmed.len == 0) continue;

        const normalized = try normalizeBibliographyText(allocator, trimmed);
        if (normalized.len == 0) continue;

        if (!first) try buf.appendSlice("; ");
        try buf.appendSlice(normalized);
        first = false;
    }

    return try buf.toOwnedSlice();
}

fn appendBibliographySentence(buf: *std.ArrayList(u8), maybe_text: ?[]const u8) !void {
    if (maybe_text) |text| {
        const trimmed = mem.trim(u8, text, " \t\r\n");
        if (trimmed.len == 0) return;

        if (buf.items.len > 0) try buf.append(' ');
        try buf.appendSlice(trimmed);
        const last = trimmed[trimmed.len - 1];
        if (last != '.' and last != '!' and last != '?') try buf.append('.');
    }
}

fn appendBibliographyQuotedTitle(buf: *std.ArrayList(u8), maybe_text: ?[]const u8) !void {
    if (maybe_text) |text| {
        const trimmed = mem.trim(u8, text, " \t\r\n");
        if (trimmed.len == 0) return;

        if (buf.items.len > 0) try buf.append(' ');
        try buf.appendSlice("\"");
        try buf.appendSlice(trimmed);
        const last = trimmed[trimmed.len - 1];
        if (last != '.' and last != '!' and last != '?') try buf.append('.');
        try buf.appendSlice("\"");
    }
}

fn appendBibliographyClause(buf: *std.ArrayList(u8), maybe_text: ?[]const u8, label: ?[]const u8) !void {
    if (maybe_text) |text| {
        const trimmed = mem.trim(u8, text, " \t\r\n");
        if (trimmed.len == 0) return;

        if (buf.items.len > 0) try buf.appendSlice(", ");
        if (label) |prefix| {
            try buf.appendSlice(prefix);
        }
        try buf.appendSlice(trimmed);
    }
}

fn appendBibliographyLabeledSentence(buf: *std.ArrayList(u8), label: []const u8, maybe_text: ?[]const u8) !void {
    if (maybe_text) |text| {
        const trimmed = mem.trim(u8, text, " \t\r\n");
        if (trimmed.len == 0) return;

        if (buf.items.len > 0) try buf.append(' ');
        try buf.appendSlice(label);
        try buf.appendSlice(trimmed);
        const last = trimmed[trimmed.len - 1];
        if (last != '.' and last != '!' and last != '?') try buf.append('.');
    }
}

fn formatBibliographyEntry(
    allocator: mem.Allocator,
    authors: ?[]const u8,
    title: ?[]const u8,
    venue: ?[]const u8,
    volume: ?[]const u8,
    issue: ?[]const u8,
    pages: ?[]const u8,
    year: ?[]const u8,
    doi: ?[]const u8,
    url: ?[]const u8,
) ![]const u8 {
    var buf = std.ArrayList(u8).init(allocator);
    errdefer buf.deinit();

    try appendBibliographySentence(&buf, authors);
    try appendBibliographyQuotedTitle(&buf, title);

    var venue_buf = std.ArrayList(u8).init(allocator);
    defer venue_buf.deinit();
    try appendBibliographyClause(&venue_buf, venue, null);
    try appendBibliographyClause(&venue_buf, volume, "vol. ");
    try appendBibliographyClause(&venue_buf, issue, "no. ");
    try appendBibliographyClause(&venue_buf, pages, "pp. ");
    try appendBibliographyClause(&venue_buf, year, null);
    if (venue_buf.items.len > 0) {
        try appendBibliographySentence(&buf, venue_buf.items);
    }

    try appendBibliographyLabeledSentence(&buf, "DOI: ", doi);
    try appendBibliographyLabeledSentence(&buf, "URL: ", url);

    return try buf.toOwnedSlice();
}

fn parseBibtexSegment(
    allocator: mem.Allocator,
    segment: []const u8,
    authors: *?[]const u8,
    title: *?[]const u8,
    venue: *?[]const u8,
    volume: *?[]const u8,
    issue: *?[]const u8,
    pages: *?[]const u8,
    year: *?[]const u8,
    doi: *?[]const u8,
    url: *?[]const u8,
) !void {
    const trimmed = mem.trim(u8, segment, " \t\r\n,");
    if (trimmed.len == 0) return;

    var depth: usize = 0;
    var in_quote = false;
    var eq_index: ?usize = null;
    for (trimmed, 0..) |char, i| {
        switch (char) {
            '"' => {
                in_quote = !in_quote;
            },
            '{' => {
                if (!in_quote) depth += 1;
            },
            '}' => {
                if (!in_quote and depth > 0) depth -= 1;
            },
            '=' => if (!in_quote and depth == 0) {
                eq_index = i;
                break;
            },
            else => {},
        }
    }

    const split_at = eq_index orelse return;
    const name = mem.trim(u8, trimmed[0..split_at], " \t\r\n");
    const value = mem.trim(u8, trimmed[split_at + 1 ..], " \t\r\n");
    if (name.len == 0 or value.len == 0) return;

    if (std.ascii.eqlIgnoreCase(name, "author")) {
        authors.* = try normalizeBibtexAuthors(allocator, value);
    } else if (std.ascii.eqlIgnoreCase(name, "title")) {
        title.* = try normalizeBibliographyText(allocator, value);
    } else if (std.ascii.eqlIgnoreCase(name, "journal") or
        std.ascii.eqlIgnoreCase(name, "booktitle") or
        std.ascii.eqlIgnoreCase(name, "publisher") or
        std.ascii.eqlIgnoreCase(name, "howpublished")) {
        if (venue.* == null) {
            venue.* = try normalizeBibliographyText(allocator, value);
        }
    } else if (std.ascii.eqlIgnoreCase(name, "year")) {
        year.* = try normalizeBibliographyText(allocator, value);
    } else if (std.ascii.eqlIgnoreCase(name, "doi")) {
        doi.* = try normalizeBibliographyText(allocator, value);
    } else if (std.ascii.eqlIgnoreCase(name, "volume")) {
        volume.* = try normalizeBibliographyText(allocator, value);
    } else if (std.ascii.eqlIgnoreCase(name, "number") or std.ascii.eqlIgnoreCase(name, "issue")) {
        issue.* = try normalizeBibliographyText(allocator, value);
    } else if (std.ascii.eqlIgnoreCase(name, "pages")) {
        pages.* = try normalizeBibliographyText(allocator, value);
    } else if (std.ascii.eqlIgnoreCase(name, "url")) {
        url.* = try normalizeBibliographyText(allocator, value);
    }
}

fn parseBibtexEntry(allocator: mem.Allocator, entry_body: []const u8, entries: *markdown.BibliographyEntries) !void {
    const comma = mem.indexOfScalar(u8, entry_body, ',') orelse return;
    const raw_key = mem.trim(u8, entry_body[0..comma], " \t\r\n");
    if (raw_key.len == 0) return;

    const cite_key = try allocator.dupe(u8, raw_key);
    const fields = entry_body[comma + 1 ..];

    var authors: ?[]const u8 = null;
    var title: ?[]const u8 = null;
    var venue: ?[]const u8 = null;
    var volume: ?[]const u8 = null;
    var issue: ?[]const u8 = null;
    var pages: ?[]const u8 = null;
    var year: ?[]const u8 = null;
    var doi: ?[]const u8 = null;
    var url: ?[]const u8 = null;

    var start: usize = 0;
    var depth: usize = 0;
    var in_quote = false;
    var index: usize = 0;
    while (index <= fields.len) : (index += 1) {
        const at_end = index == fields.len;
        const char = if (at_end) ',' else fields[index];

        switch (char) {
            '"' => {
                if (!at_end) in_quote = !in_quote;
            },
            '{' => {
                if (!at_end and !in_quote) depth += 1;
            },
            '}' => {
                if (!at_end and !in_quote and depth > 0) depth -= 1;
            },
            ',' => if (!in_quote and depth == 0) {
                try parseBibtexSegment(allocator, fields[start..index], &authors, &title, &venue, &volume, &issue, &pages, &year, &doi, &url);
                start = index + 1;
            },
            else => {},
        }
    }

    const formatted = try formatBibliographyEntry(allocator, authors, title, venue, volume, issue, pages, year, doi, url);
    if (formatted.len == 0) return;

    try entries.put(cite_key, formatted);
}

fn parseBibtexBibliography(allocator: mem.Allocator, raw: []const u8, entries: *markdown.BibliographyEntries) !void {
    var index: usize = 0;
    while (mem.indexOfScalarPos(u8, raw, index, '@')) |at_index| {
        var open_index = at_index + 1;
        while (open_index < raw.len and raw[open_index] != '{' and raw[open_index] != '(') : (open_index += 1) {}
        if (open_index >= raw.len) break;

        const entry_type = mem.trim(u8, raw[at_index + 1 .. open_index], " \t\r\n");
        index = open_index + 1;

        if (std.ascii.eqlIgnoreCase(entry_type, "comment") or
            std.ascii.eqlIgnoreCase(entry_type, "preamble") or
            std.ascii.eqlIgnoreCase(entry_type, "string")) {
            continue;
        }

        const open_char = raw[open_index];
        const close_char: u8 = if (open_char == '{') '}' else ')';
        var depth: usize = 1;
        var in_quote = false;
        var cursor = open_index + 1;
        while (cursor < raw.len and depth > 0) : (cursor += 1) {
            const char = raw[cursor];
            switch (char) {
                '"' => {
                    if (cursor == 0 or raw[cursor - 1] != '\\') in_quote = !in_quote;
                },
                else => {
                    if (!in_quote) {
                        if (char == open_char) {
                            depth += 1;
                        } else if (char == close_char) {
                            depth -= 1;
                        }
                    }
                },
            }
        }
        if (depth != 0 or cursor == 0) break;

        try parseBibtexEntry(allocator, raw[open_index + 1 .. cursor - 1], entries);
        index = cursor;
    }
}

fn jsonObjectString(value: std.json.Value, key: []const u8) ?[]const u8 {
    if (value != .object) return null;
    const field = value.object.get(key) orelse return null;
    return switch (field) {
        .string => |s| s,
        else => null,
    };
}

fn jsonObjectStringLike(allocator: mem.Allocator, value: std.json.Value, key: []const u8) !?[]const u8 {
    if (value != .object) return null;
    const field = value.object.get(key) orelse return null;
    return switch (field) {
        .string => |s| try allocator.dupe(u8, s),
        .array => |items| blk: {
            for (items.items) |entry| {
                if (entry == .string and entry.string.len > 0) {
                    break :blk try allocator.dupe(u8, entry.string);
                }
            }
            break :blk null;
        },
        else => null,
    };
}

fn jsonObjectYear(allocator: mem.Allocator, value: std.json.Value) !?[]const u8 {
    if (value != .object) return null;

    if (value.object.get("year")) |year_value| {
        return switch (year_value) {
            .string => |s| try allocator.dupe(u8, s),
            .integer => |n| try std.fmt.allocPrint(allocator, "{d}", .{n}),
            .float => |n| try std.fmt.allocPrint(allocator, "{d}", .{@as(i64, @intFromFloat(n))}),
            else => null,
        };
    }

    if (value.object.get("issued")) |issued_value| {
        if (issued_value == .object) {
            if (issued_value.object.get("raw")) |raw_value| {
                if (raw_value == .string) return try allocator.dupe(u8, raw_value.string);
            }

            if (issued_value.object.get("date-parts")) |parts| {
                if (parts == .array and parts.array.items.len > 0) {
                    const first = parts.array.items[0];
                    if (first == .array and first.array.items.len > 0) {
                        const first_year = first.array.items[0];
                        return switch (first_year) {
                            .string => |s| try allocator.dupe(u8, s),
                            .integer => |n| try std.fmt.allocPrint(allocator, "{d}", .{n}),
                            .float => |n| try std.fmt.allocPrint(allocator, "{d}", .{@as(i64, @intFromFloat(n))}),
                            else => null,
                        };
                    }
                }
            }
        }
    }

    return null;
}

fn jsonObjectAuthors(allocator: mem.Allocator, value: std.json.Value) !?[]const u8 {
    if (value != .object) return null;
    const authors_value = value.object.get("author") orelse return null;
    if (authors_value != .array) return null;

    var buf = std.ArrayList(u8).init(allocator);
    errdefer buf.deinit();

    for (authors_value.array.items, 0..) |author_value, index| {
        if (author_value != .object) continue;

        const literal = jsonObjectString(author_value, "literal");
        const family = jsonObjectString(author_value, "family");
        const given = jsonObjectString(author_value, "given");
        const raw_name = literal orelse blk: {
            if (family) |family_name| {
                if (given) |given_name| {
                    break :blk try std.fmt.allocPrint(allocator, "{s}, {s}", .{ family_name, given_name });
                }
                break :blk family_name;
            }
            break :blk given orelse "";
        };

        const normalized = try normalizeBibliographyText(allocator, raw_name);
        if (normalized.len == 0) continue;

        if (index > 0 and buf.items.len > 0) try buf.appendSlice("; ");
        try buf.appendSlice(normalized);
    }

    if (buf.items.len == 0) return null;
    return try buf.toOwnedSlice();
}

fn parseCslJsonValue(allocator: mem.Allocator, value: std.json.Value, entries: *markdown.BibliographyEntries) !void {
    if (value != .object) return;

    const raw_id = jsonObjectString(value, "id") orelse return;
    const cite_key = try allocator.dupe(u8, raw_id);

    const authors = try jsonObjectAuthors(allocator, value);
    const raw_title = try jsonObjectStringLike(allocator, value, "title");
    const title = if (raw_title) |field| try normalizeBibliographyText(allocator, field) else null;
    const raw_venue = (try jsonObjectStringLike(allocator, value, "container-title")) orelse (try jsonObjectStringLike(allocator, value, "publisher"));
    const venue = if (raw_venue) |field| try normalizeBibliographyText(allocator, field) else null;
    const raw_volume = try jsonObjectStringLike(allocator, value, "volume");
    const volume = if (raw_volume) |field| try normalizeBibliographyText(allocator, field) else null;
    const raw_issue = (try jsonObjectStringLike(allocator, value, "issue")) orelse (try jsonObjectStringLike(allocator, value, "number"));
    const issue = if (raw_issue) |field| try normalizeBibliographyText(allocator, field) else null;
    const raw_pages = try jsonObjectStringLike(allocator, value, "page");
    const pages = if (raw_pages) |field| try normalizeBibliographyText(allocator, field) else null;
    const year = try jsonObjectYear(allocator, value);
    const raw_doi = (try jsonObjectStringLike(allocator, value, "DOI")) orelse (try jsonObjectStringLike(allocator, value, "doi"));
    const doi = if (raw_doi) |field| try normalizeBibliographyText(allocator, field) else null;
    const raw_url = (try jsonObjectStringLike(allocator, value, "URL")) orelse (try jsonObjectStringLike(allocator, value, "url"));
    const url = if (raw_url) |field| try normalizeBibliographyText(allocator, field) else null;

    const formatted = try formatBibliographyEntry(allocator, authors, title, venue, volume, issue, pages, year, doi, url);
    if (formatted.len == 0) return;

    try entries.put(cite_key, formatted);
}

fn parseCslJsonBibliography(allocator: mem.Allocator, raw: []const u8, entries: *markdown.BibliographyEntries) !void {
    const parsed = try std.json.parseFromSlice(std.json.Value, allocator, raw, .{});
    defer parsed.deinit();

    switch (parsed.value) {
        .array => |array| {
            for (array.items) |item| {
                try parseCslJsonValue(allocator, item, entries);
            }
        },
        .object => |object| {
            if (object.get("items")) |items| {
                if (items == .array) {
                    for (items.array.items) |item| {
                        try parseCslJsonValue(allocator, item, entries);
                    }
                    return;
                }
            }

            try parseCslJsonValue(allocator, parsed.value, entries);
        },
        else => return,
    }
}

fn loadBibliographyEntries(allocator: mem.Allocator, site_root: []const u8, bibliography_path: []const u8) !markdown.BibliographyEntries {
    const path = if (fs.path.isAbsolute(bibliography_path))
        try allocator.dupe(u8, bibliography_path)
    else
        try fs.path.join(allocator, &.{ site_root, bibliography_path });

    var file = try fs.openFileAbsolute(path, .{});
    defer file.close();

    const raw = try file.readToEndAlloc(allocator, math.maxInt(u32));
    var entries = markdown.BibliographyEntries.init(allocator);

    const ext = fs.path.extension(path);
    if (mem.eql(u8, ext, ".bib")) {
        try parseBibtexBibliography(allocator, raw, &entries);
    } else if (mem.eql(u8, ext, ".json")) {
        try parseCslJsonBibliography(allocator, raw, &entries);
    } else {
        return error.UnsupportedBibliographyFormat;
    }

    return entries;
}

pub fn dispatch(site: *Site, slug: []const u8, writer: anytype, styles_writer: anytype, scripts_writer: anytype, options: DispatchOptions) DispatchError!void {
    // Clear style and script maps between page navigations
    site.component_assets.script_map.clearRetainingCapacity();
    site.component_assets.style_map.clearRetainingCapacity();

    log.debug("Dispatch request for slug ({s})", .{slug});
    var stmt = site.db.db.prepare(
        \\SELECT filepath, template FROM pages WHERE slug = ?;
        ,
    ) catch return error.DbError;
    defer stmt.deinit();

    if (stmt.oneAlloc(struct { filepath: []const u8, template: []const u8 }, site.allocator, .{}, .{ .slug = slug }) catch return DispatchError.DbError) |row| {
        var arena = heap.ArenaAllocator.init(site.allocator);
        defer arena.deinit();
        const ally = arena.allocator();

        const filepath = row.filepath;
        const site_root = site.site_root;
        const db = site.db;
        const url_prefix = site.url_prefix orelse "";

        // Read the file contents
        const contents = contents: {
            const in_file = fs.openFileAbsolute(
                filepath,
                .{},
            ) catch return DispatchError.ReadError;
            defer in_file.close();

            break :contents in_file.readToEndAlloc(
                ally,
                math.maxInt(u32),
            ) catch return DispatchError.OOM;
        };

        // Parse the Page metadata
        const result = page.CodeFence.parse(contents) orelse
            return error.RenderError;

        const p: page.Page = .{
            .markdown = .{
                .frontmatter = result.within,
                .content = result.after,
            },
        };

        switch (options.wants) {
            .wants_raw => {
                writer.print("---\n{s}\n---\n{s}\n", .{ p.markdown.frontmatter, p.markdown.content }) catch {};
            },
            else => {
                const data = p.data(ally) catch return DispatchError.RenderError;

                var html_buffer = io.bufferedWriter(writer);
                var styles_buffer = io.bufferedWriter(styles_writer);
                var scripts_buffer = io.bufferedWriter(scripts_writer);

                // Load the template from the filesystem
                const template = template: {
                    if (data.template) |t| {
                        const template_path = fs.path.join(
                            ally,
                            &.{ site_root, "templates", t },
                        ) catch return DispatchError.OOM;

                        var template_file = fs.openFileAbsolute(
                            template_path,
                            .{},
                        ) catch return DispatchError.ReadError;
                        defer template_file.close();

                        const template = template_file.readToEndAlloc(
                            ally,
                            math.maxInt(u32),
                        ) catch return DispatchError.OOM;
                        break :template template;
                    }

                    break :template fallback_template;
                };

                renderPage(
                    ally,
                    p,
                    .{ .bytes = template },
                    db,
                    site.component_assets,
                    site_root,
                    url_prefix,
                    site.resolveTheme(data.theme),
                    &site.asset_manifest,
                    null,
                    options.wants,
                    html_buffer.writer(),
                ) catch return DispatchError.RenderError;

                html_buffer.flush() catch {};
                styles_buffer.flush() catch {};
                scripts_buffer.flush() catch {};
            },
        }
    } else {
        return DispatchError.NotFound;
    }
}

/// Write `page` as an html document to the `writer`.
///
/// TODO Assuming that the allocator is an arena.
fn renderPage(
    allocator: mem.Allocator,
    p: page.Page,
    tmpl: TemplateOption,
    db: *Database,
    component_assets: *ComponentAssets,
    site_root: []const u8,
    url_prefix: ?[]const u8,
    selected_theme: ?*const theme.Theme,
    asset_manifest: *const assets.Manifest,
    pagination: ?Pagination,
    wants: DispatchWants,
    writer: anytype,
) !void {
    const wants2 = e: switch (wants) {
        .wants_raw => unreachable,
        else => |e| break :e e,
    };

    const meta = try p.data(allocator);
    defer meta.deinit(allocator);

    log.info(
        "Render ({s})[{s}]",
        .{ meta.title.?, meta.slug },
    );

    var bibliography_arena = heap.ArenaAllocator.init(allocator);
    defer bibliography_arena.deinit();

    var bibliography_entries: ?markdown.BibliographyEntries = null;
    if (meta.bibliography) |bibliography_path| {
        bibliography_entries = try loadBibliographyEntries(bibliography_arena.allocator(), site_root, bibliography_path);
    }

    const interactive = try markdown.preprocessInteractiveFigures(allocator, p.markdown.content);
    defer interactive.deinit(allocator);

    const should_render_mustache = meta.allow_html or interactive.requires_mustache;
    const content = if (should_render_mustache) content: {
        var buf = std.ArrayList(u8).init(allocator);
        defer buf.deinit();

        try mustache.renderStream(
            allocator,
            interactive.content,
            .{
                .db = db,
                .data = meta,
                .site_root = url_prefix orelse "",
                .component_assets = component_assets,
                .theme = selected_theme,
                .asset_manifest = asset_manifest,
                .pagination = pagination,
            },
            buf.writer(),
        );
        break :content try buf.toOwnedSlice();
    } else interactive.content;
    defer if (should_render_mustache) allocator.free(content);

    const template = tmpl.bytes;

    const rendered = try markdown.renderAlloc(
        allocator,
        content,
        .{
            .url_prefix = url_prefix,
            .bibliography_entries = if (bibliography_entries) |*entries| entries else null,
            .asset_manifest = @constCast(asset_manifest),
        },
    );
    defer rendered.deinit(allocator);

    var content_buf = std.ArrayList(u8).init(allocator);
    defer content_buf.deinit();
    try content_buf.appendSlice(rendered.html);

    switch (wants2) {
        .wants_editor => {
            const editor_inline_script = "<script>" ++ @embedFile("editor_inline_script.js") ++ "</script>";
            try content_buf.appendSlice(editor_inline_script);
            const editor_inline_styles = "<style>" ++ @embedFile("editor_inline_styles.css") ++ "</style>";
            try content_buf.appendSlice(editor_inline_styles);
        },
        .wants_content => {},
        .wants_raw => unreachable,
    }

    try mustache.renderStream(
        allocator,
        template,
        .{
            .db = db,
            .data = meta,
            .content = content_buf.items,
            .site_root = url_prefix orelse "",
            .component_assets = component_assets,
            .theme = selected_theme,
            .asset_manifest = asset_manifest,
            .pagination = pagination,
            .rendered = rendered,
        },
        writer,
    );
}

fn paginationSlug(allocator: mem.Allocator, page_ctx: Pagination) ![]const u8 {
    if (page_ctx.current_page <= 1) {
        return page_ctx.base_slug;
    }

    return if (mem.eql(u8, page_ctx.base_slug, "/"))
        try std.fmt.allocPrint(allocator, "/page/{d}", .{page_ctx.current_page})
    else
        try std.fmt.allocPrint(allocator, "{s}/page/{d}", .{ page_ctx.base_slug, page_ctx.current_page });
}

const @"test" = struct {
    /// Test that the provided content is rendered correctly.
    pub fn content(expected: []const u8, markdown_content: []const u8) !void {
        const page_to_render: page.Page = .{
            .markdown = .{
                .content = markdown_content,

                .frontmatter =
                \\---
                \\slug: /
                \\title: Hello, world!
                \\template: foo.html
                \\---
                ,
            },
        };

        const template = "{{&content}}";

        var db = blk: {
            var db = try Database.init(testing.allocator);

            try storage.Page.init(&db);
            try storage.Template.init(&db);
            break :blk db;
        };

        defer db.deinit();

        var buf = std.ArrayList(u8).init(testing.allocator);
        defer buf.deinit();

        var component_assets = try ComponentAssets.init(testing.allocator, &db);
        defer component_assets.deinit();

        var asset_manifest = assets.Manifest.init(testing.allocator);
        defer asset_manifest.deinit();

        try renderPage(
            testing.allocator,
            page_to_render,
            .{ .bytes = template },
            &db,
            &component_assets,
            "/",
            null,
            null,
            &asset_manifest,
            null,
            .wants_content,
            buf.writer(),
        );

        try testing.expectEqualStrings(expected, buf.items);
    }
};

test renderPage {
    try @"test".content(
        "<p>\nHello, world!</p>",
        \\Hello, world!
        ,
    );
}

test "parseBibtexBibliography preserves richer fields" {
    var arena = heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();

    var entries = markdown.BibliographyEntries.init(arena.allocator());
    try parseBibtexBibliography(
        arena.allocator(),
        \\@article{smith2024,
        \\  author = {Smith, Jane and Doe, Alex},
        \\  title = {Calibration for Example Models},
        \\  journal = {Journal of Testing},
        \\  volume = {12},
        \\  number = {3},
        \\  pages = {44--58},
        \\  year = {2024},
        \\  doi = {10.1000/example},
        \\  url = {https://example.com/paper}
        \\}
        ,
        &entries,
    );

    const entry = entries.get("smith2024").?;
    try testing.expectEqualStrings(
        "Smith, Jane; Doe, Alex. \"Calibration for Example Models.\" Journal of Testing, vol. 12, no. 3, pp. 44--58, 2024. DOI: 10.1000/example. URL: https://example.com/paper.",
        entry,
    );
}

test "parseCslJsonBibliography preserves richer fields" {
    var arena = heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();

    var entries = markdown.BibliographyEntries.init(arena.allocator());
    try parseCslJsonBibliography(
        arena.allocator(),
        \\[
        \\  {
        \\    "id": "lee2023",
        \\    "author": [
        \\      { "family": "Lee", "given": "Mina" },
        \\      { "literal": "Samuel Okafor" }
        \\    ],
        \\    "title": "Margin Notes For Computational Essays",
        \\    "container-title": ["Proceedings of the Fictional Symposium on Digital Publishing"],
        \\    "volume": "4",
        \\    "issue": "1",
        \\    "page": "10-19",
        \\    "issued": { "date-parts": [[2023]] },
        \\    "DOI": "10.1000/csl-example",
        \\    "URL": "https://example.com/csl"
        \\  }
        \\]
        ,
        &entries,
    );

    const entry = entries.get("lee2023").?;
    try testing.expectEqualStrings(
        "Lee, Mina; Samuel Okafor. \"Margin Notes For Computational Essays.\" Proceedings of the Fictional Symposium on Digital Publishing, vol. 4, no. 1, pp. 10-19, 2023. DOI: 10.1000/csl-example. URL: https://example.com/csl.",
        entry,
    );
}
