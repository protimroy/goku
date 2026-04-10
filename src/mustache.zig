const assets = @import("assets.zig");
const c = @import("c");
const debug = std.debug;
const fmt = std.fmt;
const fs = std.fs;
const js = @import("js.zig");
const heap = std.heap;
const log = std.log.scoped(.mustache);
const htm = @import("htm");
const vhtml = @import("vhtml");
const lucide = @import("lucide");
const markdown = @import("markdown.zig");
const math = std.math;
const mem = std.mem;
const std = @import("std");
const storage = @import("storage.zig");
const testing = std.testing;
const ComponentAssets = @import("Site.zig").ComponentAssets;
const Pagination = @import("Site.zig").Pagination;
const Theme = @import("theme.zig").Theme;

pub fn renderStream(allocator: mem.Allocator, template: []const u8, context: anytype, writer: anytype) !void {
    var arena = heap.ArenaAllocator.init(allocator);
    defer arena.deinit();

    var mustache_writer = MustacheWriterType(@TypeOf(context), @TypeOf(writer)).init(
        arena.allocator(),
        context,
        writer,
    );

    try mustache_writer.write(template);
}

test renderStream {
    var buf: std.Io.Writer.Allocating = .init(testing.allocator);
    defer buf.deinit();

    const template = "{{title}}";

    var db = try @import("Database.zig").init(testing.allocator);
    try storage.Page.init(&db);
    try storage.Template.init(&db);
    defer db.deinit();

    var component_assets = try ComponentAssets.init(testing.allocator, &db);
    defer component_assets.deinit();

    try renderStream(
        testing.allocator,
        template,
        .{
            .db = db,
            .site_root = "/",
            .component_assets = &component_assets,
            .data = .{
                .title = "foo",
                .slug = "/foo",
            },
        },
        &buf.writer,
    );

    try testing.expectEqualStrings("foo", buf.written());
}

fn appendFmt(buf: *std.array_list.Managed(u8), comptime format: []const u8, args: anytype) !void {
    const rendered = try fmt.allocPrint(buf.allocator, format, args);
    defer buf.allocator.free(rendered);
    try buf.appendSlice(rendered);
}

fn GetHandleType(comptime UserContext: type) type {
    return struct {
        user_context: UserContext,

        const GetHandle = @This();

        pub fn getKnown(get_handle: *GetHandle, arena: mem.Allocator, key: []const u8) !?[]const u8 {
            // These are known goku constants that are expected to be available during page rendering.
            const context_keys = &.{ "content", "site_root" };

            // At runtime, if a template tries to get one of these keys, we look for it in Context.
            // If the key is found, we populate the buf with a copy.
            // Otherwise, we return a runtime error.
            // ---
            // Really, in the application there are two kinds of rendering
            // the preprocess pass on the content and the final rendering pass
            // where the content is known.
            // In the first, these context keys are not present - ideally
            // we encode that logic where this is being called, rather than
            // in two separate places
            inline for (context_keys) |context_key| {
                if (mem.eql(u8, key, context_key)) {
                    if (!@hasField(UserContext, context_key)) return error.ContextMissingRequestedKey;

                    return try arena.dupeZ(u8, @field(get_handle.user_context, context_key));
                }
            }

            return null;
        }

        fn getData(get_handle: *GetHandle, arena: mem.Allocator, key: []const u8) !?[]const u8 {
            inline for (@typeInfo(@TypeOf(get_handle.user_context.data)).@"struct".fields) |f| {
                if (mem.eql(u8, key, f.name)) {
                    switch (@typeInfo(f.type)) {
                        .optional => {
                            const value = @field(get_handle.user_context.data, f.name);

                            if (value) |v| {
                                switch (@typeInfo(@TypeOf(v))) {
                                    .pointer => return try arena.dupeZ(u8, v),
                                    .int, .comptime_int => return try fmt.allocPrint(arena, "{d}", .{v}),
                                    .bool => return if (v) "true" else "false",
                                    else => return error.UnsupportedDataFieldType,
                                }
                            }

                            return "";
                        },
                        .bool => {
                            return if (@field(get_handle.user_context.data, f.name)) "true" else "false";
                        },
                        else => {
                            return try arena.dupeZ(
                                u8,
                                @field(get_handle.user_context.data, f.name),
                            );
                        },
                    }
                }
            }

            return null;
        }

        fn getCollectionsList(get_handle: *GetHandle, arena: mem.Allocator, collection: []const u8) ![]const u8 {
            var list_buf = std.array_list.Managed(u8).init(arena);
            defer list_buf.deinit();

            const pagination = getPagination(get_handle, collection);
            const get_pages = .{
                .stmt =
                \\SELECT slug, date, title
                \\FROM pages
                \\WHERE collection = ?
                \\AND slug != ?
                \\ORDER BY date DESC, title ASC
                \\LIMIT ? OFFSET ?
                ,
                .type = struct {
                    slug: []const u8,
                    date: []const u8,
                    title: []const u8,
                },
            };

            var get_stmt = try get_handle.user_context.db.db.prepare(get_pages.stmt);
            defer get_stmt.deinit();

            const limit: u32 = if (pagination) |page_ctx| page_ctx.per_page else std.math.maxInt(u32);
            const offset: u32 = if (pagination) |page_ctx| (page_ctx.current_page - 1) * page_ctx.per_page else 0;

            var it = try get_stmt.iterator(
                get_pages.type,
                .{
                    .collection = collection,
                    .slug = get_handle.user_context.data.slug,
                    .limit = limit,
                    .offset = offset,
                },
            );

            try list_buf.appendSlice("<ul>");

            var num_items: u32 = 0;
            while (try it.nextAlloc(arena, .{})) |entry| {
                try appendFmt(&list_buf,
                    \\<li>
                    \\<a href="{[site_root]s}{[slug]s}">
                    \\{[date]s} {[title]s}
                    \\</a>
                    \\</li>
                ,
                    .{
                        .site_root = get_handle.user_context.site_root,
                        .slug = entry.slug,
                        .date = entry.date,
                        .title = entry.title,
                    },
                );

                num_items += 1;
            }

            if (num_items > 0) {
                try list_buf.appendSlice("</ul>");
                return try list_buf.toOwnedSlice();
            }

            return "";
        }

        fn getPagination(get_handle: *GetHandle, collection: []const u8) ?Pagination {
            if (!@hasField(UserContext, "pagination")) return null;

            const pagination = @field(get_handle.user_context, "pagination");
            if (pagination) |page_ctx| {
                if (mem.eql(u8, page_ctx.collection, collection)) {
                    return page_ctx;
                }
            }

            return null;
        }

        fn pageUrl(get_handle: *GetHandle, arena: mem.Allocator) ![]const u8 {
            if (@hasField(@TypeOf(get_handle.user_context.data), "canonical_url")) {
                if (@field(get_handle.user_context.data, "canonical_url")) |canonical_url| {
                    return try arena.dupe(u8, canonical_url);
                }
            }

            return try fmt.allocPrint(
                arena,
                "{s}{s}",
                .{ get_handle.user_context.site_root, get_handle.user_context.data.slug },
            );
        }

        fn getCollectionsLatest(get_handle: *GetHandle, arena: mem.Allocator, collection: []const u8) ![]const u8 {
            const get_page = .{
                .stmt =
                \\SELECT slug, title FROM pages WHERE collection = ?
                \\ORDER BY date DESC
                \\LIMIT 1
                ,
                .type = struct { slug: []const u8, title: []const u8 },
            };

            var get_stmt = try get_handle.user_context.db.db.prepare(get_page.stmt);
            defer get_stmt.deinit();

            const row = try get_stmt.oneAlloc(
                get_page.type,
                arena,
                .{},
                .{
                    .collection = collection,
                },
            ) orelse return error.EmptyCollection;

            // TODO is there a way to free this?
            //defer row.deinit();

            const value = try fmt.allocPrint(
                arena,
                \\<article>
                \\<a href="{s}{s}">{s}</a>
                \\</article>
            ,
                .{
                    get_handle.user_context.site_root,
                    row.slug,
                    row.title,
                },
            );
            errdefer arena.free(value);

            return value;
        }

        fn getMeta(get_handle: *GetHandle, arena: mem.Allocator) ![]const u8 {
            var buf = std.array_list.Managed(u8).init(arena);
            errdefer buf.deinit();
            try appendFmt(&buf,
                \\<style>.meta-container {{ font-size: .7rem; }}</style>
                \\<div class="table-container meta-container">
                \\<table class="table">
                \\<thead>
                \\<tr><th colspan="2">Meta</th></tr>
                \\</thead>
                \\<tbody>
            , .{});

            inline for (std.meta.fields(@TypeOf(get_handle.user_context.data))) |field| {
                switch (field.type) {
                    []const u8 => try appendFmt(&buf, "<tr><th>{[name]s}</th><td>{[value]s}</td>", .{
                        .name = field.name,
                        .value = @field(get_handle.user_context.data, field.name),
                    }),
                    ?[]const u8 => if (@field(get_handle.user_context.data, field.name)) |value| {
                        try appendFmt(&buf, "<tr><th>{[name]s}</th><td>{[value]s}</td>", .{
                            .name = field.name,
                            .value = value,
                        });
                    },
                    else => {},
                }
            }

            try appendFmt(&buf,
                \\</tbody>
                \\</table>
                \\</div>
            , .{});

            return try buf.toOwnedSlice();
        }

        fn renderedPage(get_handle: *GetHandle) ?markdown.Rendered {
            if (!@hasField(UserContext, "rendered")) return null;
            return @field(get_handle.user_context, "rendered");
        }

        const NeighborDirection = enum { prev, next };
        const NeighborPage = struct {
            slug: []const u8,
            title: []const u8,
        };

        fn getCollectionNeighbor(get_handle: *GetHandle, arena: mem.Allocator, direction: NeighborDirection) !?NeighborPage {
            if (!@hasField(@TypeOf(get_handle.user_context.data), "collection")) return null;
            const collection = @field(get_handle.user_context.data, "collection") orelse return null;

            var stmt = try get_handle.user_context.db.db.prepare(
                \\SELECT slug, title
                \\FROM pages
                \\WHERE collection = ?
                \\ORDER BY date DESC, title ASC
            );
            defer stmt.deinit();

            var it = try stmt.iterator(NeighborPage, .{ .collection = collection });
            var prev: ?NeighborPage = null;
            while (try it.nextAlloc(arena, .{})) |entry| {
                if (mem.eql(u8, entry.slug, get_handle.user_context.data.slug)) {
                    return switch (direction) {
                        .prev => prev,
                        .next => try it.nextAlloc(arena, .{}),
                    };
                }
                prev = entry;
            }

            return null;
        }
    };
}

const UserError = enum(u8) {
    GetFailedForKey = 1,
    EmitFailed = 2,
    _,
};

fn MustacheWriterType(comptime UserContext: type, comptime WriterType: type) type {
    return struct {
        arena: mem.Allocator,
        context: GetHandle,
        writer: WriterType,
        component_assets: *ComponentAssets,

        pub fn init(
            arena: mem.Allocator,
            user_context: UserContext,
            writer: WriterType,
        ) MustacheWriter {
            return .{
                .arena = arena,
                .context = .{ .user_context = user_context },
                .writer = writer,
                .component_assets = user_context.component_assets,
            };
        }

        const MustacheWriter = @This();
        const GetHandle = GetHandleType(UserContext);

        pub const Error = error{ UnexpectedBehaviour, CouldNotRenderTemplate };

        pub fn write(ctx: *MustacheWriter, template: []const u8) Error!void {
            mustachMem(
                template,
                @ptrCast(ctx),
                &vtable,
            ) catch |err| {
                switch (err) {
                    error.UnexpectedBehaviour,
                    error.CouldNotRenderTemplate,
                    => |e| return e,
                }
            };
        }

        const vtable: c.mustach_itf = .{
            .emit = emit,
            .get = get,
            .enter = enter,
            .next = next,
            .leave = leave,
            .partial = partial,
        };

        fn emit(ptr: ?*anyopaque, buf: [*c]const u8, len: usize, escaping: c_int, _: ?*c.FILE) callconv(.c) c_int {
            debug.assert(ptr != null);
            // Trying to emit a value we could not get?
            debug.assert(buf != null);

            Inner.emit(
                @ptrCast(@alignCast(ptr)),
                buf[0..len],
                if (escaping == 1) .escape else .raw,
            ) catch |err| {
                log.err("{any}", .{err});
                return c.MUSTACH_ERROR_USER(@intFromEnum(UserError.EmitFailed));
            };

            return 0;
        }

        // Calls the internal get implementation
        fn get(ptr: ?*anyopaque, buf: [*c]const u8, sbuf: [*c]c.struct_mustach_sbuf) callconv(.c) c_int {
            const key = mem.sliceTo(buf, 0);

            const value = Inner.get(fromPtr(ptr), key) catch |err| {
                log.err("getInner {any}", .{err});
                return c.MUSTACH_ERROR_USER(@intFromEnum(UserError.GetFailedForKey));
            } orelse {
                log.err("get failed for key ({s})", .{key});
                return c.MUSTACH_ERROR_USER(@intFromEnum(UserError.GetFailedForKey));
            };

            sbuf.* = .{
                .value = @ptrCast(value),
                .length = value.len,
                .closure = null,
            };
            return 0;
        }

        fn enter(_: ?*anyopaque, buf: [*c]const u8) callconv(.c) c_int {
            const key = mem.sliceTo(buf, 0);
            _ = key;
            // return 1 if entered, or 0 if not entered
            // When 1 is returned, the function must activate the first item of the section
            return 1;
        }

        fn next(_: ?*anyopaque) callconv(.c) c_int {
            return 0;
        }

        fn leave(_: ?*anyopaque) callconv(.c) c_int {
            return 0;
        }

        fn partial(_: ?*anyopaque, _: [*c]const u8, _: [*c]c.struct_mustach_sbuf) callconv(.c) c_int {
            return 0;
        }

        fn fromPtr(ptr: ?*anyopaque) *MustacheWriter {
            return @ptrCast(@alignCast(ptr));
        }

        const Inner = struct {
            /// Will write the contents of `buf` to an internal buffer.
            /// `emit_mode` determines whether the buf is written as-is or escaped.
            fn emit(self: *MustacheWriter, buf: []const u8, emit_mode: enum { raw, escape }) !void {
                switch (emit_mode) {
                    .raw => try self.writer.writeAll(buf),
                    .escape => {
                        for (buf) |char| {
                            switch (char) {
                                '<' => try self.writer.writeAll("&lt;"),
                                '>' => try self.writer.writeAll("&gt;"),
                                else => try self.writer.writeByte(char),
                            }
                        }
                    },
                }
            }

            const Getter = union(enum) {
                simple: *const fn (mem.Allocator, []const u8) anyerror!?[]const u8,
                ctx: *const fn (*MustacheWriter, []const u8) anyerror!?[]const u8,

                pub fn get(getter: Getter, ctx: *MustacheWriter, key: []const u8) !?[]const u8 {
                    return switch (getter) {
                        .simple => |simple_fn| simple_fn(ctx.arena, key),
                        .ctx => |ctx_fn| ctx_fn(ctx, key),
                    };
                }
            };

            const CollectionGetter = struct {
                pub fn getList(mw: *MustacheWriter, k: []const u8) !?[]const u8 {
                    const collection = getBetween("collections.", ".list", k) orelse return null;
                    return try mw.context.getCollectionsList(mw.arena, collection);
                }
                pub fn getLatest(mw: *MustacheWriter, k: []const u8) !?[]const u8 {
                    const name = getBetween("collections.", ".latest", k) orelse return null;
                    return try mw.context.getCollectionsLatest(mw.arena, name);
                }

                /// If `haystack` starts with prefix and ends with suffix, return the middle.
                fn getBetween(prefix: []const u8, suffix: []const u8, haystack: []const u8) ?[]const u8 {
                    return if (mem.startsWith(u8, haystack, prefix) and mem.endsWith(u8, haystack, suffix))
                        haystack[prefix.len .. haystack.len - suffix.len]
                    else
                        null;
                }
            };

            const LucideGetter = struct {
                pub fn getIcon(_: mem.Allocator, k: []const u8) !?[]const u8 {
                    return try getLucideIcon(k);
                }
            };

            const ContextGetter = struct {
                pub fn getKnown(mw: *MustacheWriter, k: []const u8) !?[]const u8 {
                    return try mw.context.getKnown(mw.arena, k);
                }
                pub fn getData(mw: *MustacheWriter, k: []const u8) !?[]const u8 {
                    return try mw.context.getData(mw.arena, k);
                }

                pub fn getMeta(mw: *MustacheWriter, k: []const u8) !?[]const u8 {
                    return if (mem.eql(u8, k, "meta"))
                        try mw.context.getMeta(mw.arena)
                    else
                        null;
                }

                pub fn getToc(mw: *MustacheWriter, k: []const u8) !?[]const u8 {
                    if (!mem.eql(u8, k, "toc")) return null;
                    const rendered = mw.context.renderedPage() orelse return "";
                    if (!@hasField(@TypeOf(mw.context.user_context.data), "options_toc")) return "";
                    return if (@field(mw.context.user_context.data, "options_toc")) rendered.toc_html else "";
                }

                pub fn getReadingTime(mw: *MustacheWriter, k: []const u8) !?[]const u8 {
                    if (!mem.eql(u8, k, "reading_time")) return null;
                    const rendered = mw.context.renderedPage() orelse return "";
                    return try fmt.allocPrint(mw.arena, "{d} min read", .{rendered.readingTimeMinutes()});
                }
            };

            const PageGetter = struct {
                fn fieldOrEmpty(data: anytype, comptime name: []const u8) []const u8 {
                    if (!@hasField(@TypeOf(data), name)) return "";

                    const value = @field(data, name);
                    return switch (@typeInfo(@TypeOf(value))) {
                        .optional => value orelse "",
                        .pointer => value,
                        else => "",
                    };
                }

                fn escapeHtmlAttr(arena: mem.Allocator, value: []const u8) ![]const u8 {
                    var buf = std.array_list.Managed(u8).init(arena);
                    for (value) |char| {
                        switch (char) {
                            '&' => try buf.appendSlice("&amp;"),
                            '"' => try buf.appendSlice("&quot;"),
                            '<' => try buf.appendSlice("&lt;"),
                            '>' => try buf.appendSlice("&gt;"),
                            else => try buf.append(char),
                        }
                    }
                    return try buf.toOwnedSlice();
                }

                fn normalizeUrl(mw: *MustacheWriter, value: []const u8) ![]const u8 {
                    if (mem.startsWith(u8, value, "http://") or mem.startsWith(u8, value, "https://")) {
                        return try mw.arena.dupe(u8, value);
                    }

                    if (mem.startsWith(u8, value, "/assets/") and @hasField(UserContext, "asset_manifest")) {
                        const manifest: *const assets.Manifest = @field(mw.context.user_context, "asset_manifest");
                        if (manifest.get(value["/assets/".len..])) |resolved| {
                            return try fmt.allocPrint(mw.arena, "{s}/{s}", .{ mw.context.user_context.site_root, resolved });
                        }
                    }

                    if (mem.startsWith(u8, value, "/")) {
                        return try fmt.allocPrint(mw.arena, "{s}{s}", .{ mw.context.user_context.site_root, value });
                    }
                    return try mw.arena.dupe(u8, value);
                }

                pub fn getAssetsHead(mw: *MustacheWriter, k: []const u8) !?[]const u8 {
                    if (!mem.eql(u8, k, "page_assets.head")) return null;
                    const rendered = mw.context.renderedPage() orelse return "";

                    var buf = std.array_list.Managed(u8).init(mw.arena);
                    if (rendered.has_math) {
                        try buf.appendSlice("<link rel=\"stylesheet\" href=\"https://cdn.jsdelivr.net/npm/katex@0.16.10/dist/katex.min.css\" integrity=\"sha384-hIoBPJpTUs74eN9mteA94ppIqhzyapMI2vlA38nSxrdbidK4USsfx8bVsgcuyo6S\" crossorigin=\"anonymous\">");
                    }
                    if (rendered.has_code) {
                        try buf.appendSlice("<link rel=\"stylesheet\" href=\"https://cdn.jsdelivr.net/npm/highlight.js@11.10.0/styles/github.min.css\">");
                    }
                    return if (buf.items.len == 0) "" else try buf.toOwnedSlice();
                }

                pub fn getAssetsBody(mw: *MustacheWriter, k: []const u8) !?[]const u8 {
                    if (!mem.eql(u8, k, "page_assets.body")) return null;
                    const rendered = mw.context.renderedPage() orelse return "";

                    var buf = std.array_list.Managed(u8).init(mw.arena);
                    if (rendered.has_math) {
                        try buf.appendSlice("<script defer src=\"https://cdn.jsdelivr.net/npm/katex@0.16.10/dist/katex.min.js\" crossorigin=\"anonymous\"></script><script defer src=\"https://cdn.jsdelivr.net/npm/katex@0.16.10/dist/contrib/auto-render.min.js\" crossorigin=\"anonymous\"></script><script>document.addEventListener('DOMContentLoaded', function () { if (window.renderMathInElement) { window.renderMathInElement(document.getElementById('content'), { delimiters: [{left: '\\\\(', right: '\\\\)', display: false}, {left: '\\\\[', right: '\\\\]', display: true}] }); } });</script>");
                    }
                    if (rendered.has_code) {
                        try buf.appendSlice("<script src=\"https://cdn.jsdelivr.net/npm/highlight.js@11.10.0/lib/highlight.min.js\"></script><script>document.addEventListener('DOMContentLoaded', function () { if (window.hljs) { window.hljs.highlightAll(); } });</script>");
                    }
                    return if (buf.items.len == 0) "" else try buf.toOwnedSlice();
                }

                pub fn getSeoHead(mw: *MustacheWriter, k: []const u8) !?[]const u8 {
                    if (!mem.eql(u8, k, "seo.head")) return null;

                    const page_url = try mw.context.pageUrl(mw.arena);
                    const escaped_title = try escapeHtmlAttr(mw.arena, fieldOrEmpty(mw.context.user_context.data, "title"));
                    const escaped_description = try escapeHtmlAttr(mw.arena, fieldOrEmpty(mw.context.user_context.data, "description"));
                    const escaped_page_url = try escapeHtmlAttr(mw.arena, page_url);

                    var buf = std.array_list.Managed(u8).init(mw.arena);
                    try appendFmt(&buf, "<link rel=\"canonical\" href=\"{s}\">", .{escaped_page_url});
                    if (escaped_description.len > 0) {
                        try appendFmt(&buf, "<meta name=\"description\" content=\"{s}\">", .{escaped_description});
                    }
                    try appendFmt(&buf, "<meta property=\"og:title\" content=\"{s}\"><meta property=\"og:type\" content=\"article\"><meta property=\"og:url\" content=\"{s}\">", .{ escaped_title, escaped_page_url });
                    if (escaped_description.len > 0) {
                        try appendFmt(&buf, "<meta property=\"og:description\" content=\"{s}\">", .{escaped_description});
                        try appendFmt(&buf, "<meta name=\"twitter:description\" content=\"{s}\">", .{escaped_description});
                    }
                    try appendFmt(&buf, "<meta name=\"twitter:card\" content=\"summary_large_image\"><meta name=\"twitter:title\" content=\"{s}\">", .{escaped_title});
                    if (@hasField(@TypeOf(mw.context.user_context.data), "image")) {
                        if (@field(mw.context.user_context.data, "image")) |image| {
                            const image_url = try normalizeUrl(mw, image);
                            const escaped_image_url = try escapeHtmlAttr(mw.arena, image_url);
                            try appendFmt(&buf, "<meta property=\"og:image\" content=\"{s}\"><meta name=\"twitter:image\" content=\"{s}\">", .{ escaped_image_url, escaped_image_url });
                        }
                    }
                    if (@hasField(@TypeOf(mw.context.user_context.data), "author")) {
                        if (@field(mw.context.user_context.data, "author")) |author| {
                            const escaped_author = try escapeHtmlAttr(mw.arena, author);
                            try appendFmt(&buf, "<meta name=\"author\" content=\"{s}\">", .{escaped_author});
                        }
                    }
                    if (@hasField(@TypeOf(mw.context.user_context.data), "date")) {
                        if (@field(mw.context.user_context.data, "date")) |date| {
                            const escaped_date = try escapeHtmlAttr(mw.arena, date);
                            try appendFmt(&buf, "<meta property=\"article:published_time\" content=\"{s}\">", .{escaped_date});
                        }
                    }
                    if (@hasField(@TypeOf(mw.context.user_context.data), "updated")) {
                        if (@field(mw.context.user_context.data, "updated")) |updated| {
                            const escaped_updated = try escapeHtmlAttr(mw.arena, updated);
                            try appendFmt(&buf, "<meta property=\"article:modified_time\" content=\"{s}\">", .{escaped_updated});
                        }
                    }
                    if (@hasField(@TypeOf(mw.context.user_context.data), "doi")) {
                        if (@field(mw.context.user_context.data, "doi")) |doi| {
                            const escaped_doi = try escapeHtmlAttr(mw.arena, doi);
                            try appendFmt(&buf, "<meta name=\"citation_doi\" content=\"{s}\">", .{escaped_doi});
                        }
                    }
                    return try buf.toOwnedSlice();
                }

                pub fn getPrevUrl(mw: *MustacheWriter, k: []const u8) !?[]const u8 {
                    if (!mem.eql(u8, k, "page.prev_url")) return null;
                    const prev = try mw.context.getCollectionNeighbor(mw.arena, .prev) orelse return "";
                    return try fmt.allocPrint(mw.arena, "{s}{s}", .{ mw.context.user_context.site_root, prev.slug });
                }

                pub fn getPrevTitle(mw: *MustacheWriter, k: []const u8) !?[]const u8 {
                    if (!mem.eql(u8, k, "page.prev_title")) return null;
                    const prev = try mw.context.getCollectionNeighbor(mw.arena, .prev) orelse return "";
                    return prev.title;
                }

                pub fn getNextUrl(mw: *MustacheWriter, k: []const u8) !?[]const u8 {
                    if (!mem.eql(u8, k, "page.next_url")) return null;
                    const next_page = try mw.context.getCollectionNeighbor(mw.arena, .next) orelse return "";
                    return try fmt.allocPrint(mw.arena, "{s}{s}", .{ mw.context.user_context.site_root, next_page.slug });
                }

                pub fn getNextTitle(mw: *MustacheWriter, k: []const u8) !?[]const u8 {
                    if (!mem.eql(u8, k, "page.next_title")) return null;
                    const next_page = try mw.context.getCollectionNeighbor(mw.arena, .next) orelse return "";
                    return next_page.title;
                }

                pub fn getNav(mw: *MustacheWriter, k: []const u8) !?[]const u8 {
                    if (!mem.eql(u8, k, "page.nav")) return null;

                    const prev = try mw.context.getCollectionNeighbor(mw.arena, .prev);
                    const next_page = try mw.context.getCollectionNeighbor(mw.arena, .next);
                    if (prev == null and next_page == null) return "";

                    var buf = std.array_list.Managed(u8).init(mw.arena);
                    try buf.appendSlice("<nav class=\"level page-nav\">");
                    if (prev) |entry| {
                        try appendFmt(&buf, "<a class=\"level-left\" href=\"{s}{s}\">&larr; {s}</a>", .{ mw.context.user_context.site_root, entry.slug, entry.title });
                    } else {
                        try buf.appendSlice("<span class=\"level-left\"></span>");
                    }
                    if (next_page) |entry| {
                        try appendFmt(&buf, "<a class=\"level-right\" href=\"{s}{s}\">{s} &rarr;</a>", .{ mw.context.user_context.site_root, entry.slug, entry.title });
                    } else {
                        try buf.appendSlice("<span class=\"level-right\"></span>");
                    }
                    try buf.appendSlice("</nav>");
                    return try buf.toOwnedSlice();
                }
            };

            const ComponentGetter = struct {
                pub fn getStyleRef(mw: *MustacheWriter, k: []const u8) !?[]const u8 {
                    return if (mem.eql(u8, k, "component.head"))
                        try fmt.allocPrint(
                            mw.arena,
                            \\<link rel="stylesheet" type="text/css" href="{[site_root]s}/component.css" />
                        ,
                            .{ .site_root = mw.context.user_context.site_root },
                        )
                    else
                        null;
                }

                pub fn getScriptRef(mw: *MustacheWriter, k: []const u8) !?[]const u8 {
                    return if (mem.eql(u8, k, "component.body"))
                        try fmt.allocPrint(
                            mw.arena,
                            \\<script src="{[site_root]s}/component.js"></script>
                        ,
                            .{ .site_root = mw.context.user_context.site_root },
                        )
                    else
                        null;
                }

                pub fn getComponent(mw: *MustacheWriter, k: []const u8) !?[]const u8 {
                    return if (mem.startsWith(u8, k, "component "))
                        try _getComponent(mw, k)
                    else
                        null;
                }

                fn _getComponent(mw: *MustacheWriter, k: []const u8) !?[]const u8 {
                    const component_src = src: {
                        var it = mem.tokenizeScalar(u8, k, ' ');

                        // skip component keyword
                        _ = it.next();

                        break :src it.rest();
                    };

                    var stmt = try mw.context.user_context.db.db.prepare(
                        \\SELECT filepath FROM components WHERE name = ? LIMIT 1;
                        ,
                    );
                    defer stmt.deinit();

                    const row = try stmt.oneAlloc(
                        struct { filepath: []const u8 },
                        mw.arena,
                        .{},
                        .{ .name = component_src },
                    ) orelse return error.MissingComponent;

                    var threaded_io: std.Io.Threaded = .init(mw.arena, .{});
                    defer threaded_io.deinit();

                    const fs_io = threaded_io.io();
                    var file = try std.Io.Dir.openFileAbsolute(fs_io, row.filepath, .{});
                    defer file.close(fs_io);

                    var reader_buffer: [4096]u8 = undefined;
                    var reader = file.reader(fs_io, &reader_buffer);
                    const script = try reader.interface.allocRemaining(mw.arena, .limited(math.maxInt(usize)));
                    const script_z = try mw.arena.dupeZ(u8, script);
                    defer mw.arena.free(script_z);

                    log.debug(
                        "render component ({s}) at src {s}",
                        .{ component_src, row.filepath },
                    );

                    var buf: std.Io.Writer.Allocating = .init(mw.arena);
                    defer buf.deinit();

                    renderComponent(
                        mw.arena,
                        script_z,
                        &buf.writer,
                        mw.component_assets,
                        .{
                            .site_root = mw.context.user_context.site_root,
                        },
                    ) catch |err| {
                        log.err("Failure while rendering component: {any}", .{err});
                        return err;
                    };

                    if (buf.written().len == 0) {
                        log.err("Component ({s}) did not render.", .{component_src});
                        return error.ComponentMustRender;
                    }

                    return try buf.toOwnedSlice();
                }
            };

            const AssetGetter = struct {
                pub fn getAssetPath(mw: *MustacheWriter, k: []const u8) !?[]const u8 {
                    if (!mem.startsWith(u8, k, "asset ")) return null;
                    if (!@hasField(UserContext, "asset_manifest")) return error.MissingAsset;

                    const raw_path = mem.trim(u8, k["asset ".len..], "\"'");
                    const manifest: *const assets.Manifest = @field(mw.context.user_context, "asset_manifest");
                    const resolved = manifest.get(raw_path) orelse return error.MissingAsset;
                    return try fmt.allocPrint(mw.arena, "{s}/{s}", .{ mw.context.user_context.site_root, resolved });
                }
            };

            const ThemeGetter = struct {
                fn themeAssetUrl(mw: *MustacheWriter, selected_theme: *const Theme, asset_path: []const u8) ![]const u8 {
                    if (mem.startsWith(u8, asset_path, "http://") or mem.startsWith(u8, asset_path, "https://")) {
                        return try mw.arena.dupe(u8, asset_path);
                    }

                    if (asset_path.len > 0 and asset_path[0] == '/') {
                        return try fmt.allocPrint(mw.arena, "{s}{s}", .{ mw.context.user_context.site_root, asset_path });
                    }

                    if (mem.eql(u8, asset_path, "bulma.css") or mem.eql(u8, asset_path, "htmx.js")) {
                        return try fmt.allocPrint(mw.arena, "{s}/{s}", .{ mw.context.user_context.site_root, asset_path });
                    }

                    return try fmt.allocPrint(mw.arena, "{s}/theme/{s}/{s}", .{ mw.context.user_context.site_root, selected_theme.name, asset_path });
                }

                fn selectedTheme(mw: *MustacheWriter) ?*const Theme {
                    if (!@hasField(UserContext, "theme")) return null;
                    return @field(mw.context.user_context, "theme");
                }

                fn renderStyles(mw: *MustacheWriter, selected_theme: *const Theme) ![]const u8 {
                    var buf = std.array_list.Managed(u8).init(mw.arena);
                    for (selected_theme.styles) |style| {
                        try appendFmt(&buf,
                            "<link rel=\"stylesheet\" type=\"text/css\" href=\"{s}\" />"
                        ,
                            .{try themeAssetUrl(mw, selected_theme, style)},
                        );
                    }
                    return if (buf.items.len == 0) "" else try buf.toOwnedSlice();
                }

                fn renderScripts(mw: *MustacheWriter, selected_theme: *const Theme) ![]const u8 {
                    var buf = std.array_list.Managed(u8).init(mw.arena);
                    for (selected_theme.scripts) |script| {
                        try appendFmt(&buf,
                            "<script src=\"{s}\"></script>"
                        ,
                            .{try themeAssetUrl(mw, selected_theme, script)},
                        );
                    }
                    return if (buf.items.len == 0) "" else try buf.toOwnedSlice();
                }

                pub fn getThemeHead(mw: *MustacheWriter, k: []const u8) !?[]const u8 {
                    if (!mem.eql(u8, k, "theme.head")) return null;

                    if (selectedTheme(mw)) |selected_theme| {
                        return try renderStyles(mw, selected_theme);
                    }

                    return try fmt.allocPrint(
                        mw.arena,
                        \\<link rel="stylesheet" type="text/css" href="{[site_root]s}/bulma.css" />
                    ,
                        .{ .site_root = mw.context.user_context.site_root },
                    );
                }

                pub fn getThemeBody(mw: *MustacheWriter, k: []const u8) !?[]const u8 {
                    if (!mem.eql(u8, k, "theme.body")) return null;

                    if (selectedTheme(mw)) |selected_theme| {
                        return try renderScripts(mw, selected_theme);
                    }

                    return try fmt.allocPrint(
                        mw.arena,
                        \\<script src="{[site_root]s}/htmx.js"></script>
                    ,
                        .{ .site_root = mw.context.user_context.site_root },
                    );
                }

                pub fn getThemeValue(mw: *MustacheWriter, k: []const u8) !?[]const u8 {
                    if (!mem.eql(u8, k, "theme.name")) return null;

                    if (selectedTheme(mw)) |selected_theme| {
                        return try mw.arena.dupeZ(u8, selected_theme.name);
                    }

                    return "default";
                }
            };

            const PaginationGetter = struct {
                fn currentPagination(mw: *MustacheWriter) ?Pagination {
                    if (!@hasField(UserContext, "pagination")) return null;
                    return @field(mw.context.user_context, "pagination");
                }

                fn pageUrl(mw: *MustacheWriter, base_slug: []const u8, page_number: u32) ![]const u8 {
                    if (page_number <= 1) {
                        return try fmt.allocPrint(mw.arena, "{s}{s}", .{ mw.context.user_context.site_root, base_slug });
                    }

                    return if (mem.eql(u8, base_slug, "/"))
                        try fmt.allocPrint(mw.arena, "{s}/page/{d}", .{ mw.context.user_context.site_root, page_number })
                    else
                        try fmt.allocPrint(mw.arena, "{s}{s}/page/{d}", .{ mw.context.user_context.site_root, base_slug, page_number });
                }

                pub fn getCurrent(mw: *MustacheWriter, k: []const u8) !?[]const u8 {
                    if (!mem.eql(u8, k, "pagination.current")) return null;
                    const pagination = currentPagination(mw) orelse return "";
                    return try fmt.allocPrint(mw.arena, "{d}", .{pagination.current_page});
                }

                pub fn getTotal(mw: *MustacheWriter, k: []const u8) !?[]const u8 {
                    if (!mem.eql(u8, k, "pagination.total")) return null;
                    const pagination = currentPagination(mw) orelse return "";
                    return try fmt.allocPrint(mw.arena, "{d}", .{pagination.totalPages()});
                }

                pub fn getPrevUrl(mw: *MustacheWriter, k: []const u8) !?[]const u8 {
                    if (!mem.eql(u8, k, "pagination.prev_url")) return null;
                    const pagination = currentPagination(mw) orelse return "";
                    if (pagination.current_page <= 1) return "";
                    return try pageUrl(mw, pagination.base_slug, pagination.current_page - 1);
                }

                pub fn getNextUrl(mw: *MustacheWriter, k: []const u8) !?[]const u8 {
                    if (!mem.eql(u8, k, "pagination.next_url")) return null;
                    const pagination = currentPagination(mw) orelse return "";
                    if (pagination.current_page >= pagination.totalPages()) return "";
                    return try pageUrl(mw, pagination.base_slug, pagination.current_page + 1);
                }

                pub fn getNav(mw: *MustacheWriter, k: []const u8) !?[]const u8 {
                    if (!mem.eql(u8, k, "pagination.nav")) return null;
                    const pagination = currentPagination(mw) orelse return "";
                    if (pagination.totalPages() <= 1) return "";

                    var buf = std.array_list.Managed(u8).init(mw.arena);
                    try buf.appendSlice("<nav class=\"pagination\">");

                    if (pagination.current_page > 1) {
                        try appendFmt(&buf, "<a href=\"{s}\">Previous</a>", .{try pageUrl(mw, pagination.base_slug, pagination.current_page - 1)});
                    }
                    try appendFmt(&buf, "<span>Page {d} of {d}</span>", .{ pagination.current_page, pagination.totalPages() });
                    if (pagination.current_page < pagination.totalPages()) {
                        try appendFmt(&buf, "<a href=\"{s}\">Next</a>", .{try pageUrl(mw, pagination.base_slug, pagination.current_page + 1)});
                    }

                    try buf.appendSlice("</nav>");
                    return try buf.toOwnedSlice();
                }
            };

            fn get(ctx: *MustacheWriter, key: []const u8) !?[]const u8 {
                const getters: []const Getter = &.{
                    .{ .ctx = ContextGetter.getKnown },
                    .{ .ctx = ContextGetter.getData },
                    .{ .ctx = ContextGetter.getMeta },
                    .{ .ctx = ContextGetter.getToc },
                    .{ .ctx = ContextGetter.getReadingTime },
                    .{ .simple = LucideGetter.getIcon },
                    .{ .ctx = CollectionGetter.getList },
                    .{ .ctx = CollectionGetter.getLatest },
                    .{ .ctx = PaginationGetter.getCurrent },
                    .{ .ctx = PaginationGetter.getTotal },
                    .{ .ctx = PaginationGetter.getPrevUrl },
                    .{ .ctx = PaginationGetter.getNextUrl },
                    .{ .ctx = PaginationGetter.getNav },
                    .{ .ctx = ComponentGetter.getStyleRef },
                    .{ .ctx = ComponentGetter.getScriptRef },
                    .{ .ctx = ComponentGetter.getComponent },
                    .{ .ctx = PageGetter.getAssetsHead },
                    .{ .ctx = PageGetter.getAssetsBody },
                    .{ .ctx = PageGetter.getSeoHead },
                    .{ .ctx = PageGetter.getPrevUrl },
                    .{ .ctx = PageGetter.getPrevTitle },
                    .{ .ctx = PageGetter.getNextUrl },
                    .{ .ctx = PageGetter.getNextTitle },
                    .{ .ctx = PageGetter.getNav },
                    .{ .ctx = AssetGetter.getAssetPath },
                    .{ .ctx = ThemeGetter.getThemeHead },
                    .{ .ctx = ThemeGetter.getThemeBody },
                    .{ .ctx = ThemeGetter.getThemeValue },
                };

                for (getters) |getter| {
                    if (try getter.get(ctx, key)) |value| {
                        return value;
                    }
                }

                return null;
            }
        };
    };
}
fn mustachMem(template: []const u8, closure: ?*anyopaque, vtable: *const c.mustach_itf) !void {
    var result: [*c]const u8 = null;
    var result_len: usize = undefined;

    const return_val = c.mustach_mem(
        @ptrCast(template),
        template.len,
        vtable,
        closure,
        0,
        @ptrCast(&result),
        &result_len,
    );

    switch (return_val) {
        c.MUSTACH_OK => {
            // We provide our own emit callback so any result written
            // by mustach is undefined behaviour
            if (result_len != 0) return error.UnexpectedBehaviour;
            // We don't expect mustach to write anything to result, but it does
            // modify the address in result for some reason? In any case, here
            // we make sure that it's the empty string if it is set.
            if (result != null and result[0] != 0) return error.UnexpectedBehaviour;
        },
        c.MUSTACH_ERROR_SYSTEM,
        c.MUSTACH_ERROR_INVALID_ITF,
        c.MUSTACH_ERROR_UNEXPECTED_END,
        c.MUSTACH_ERROR_BAD_UNESCAPE_TAG,
        c.MUSTACH_ERROR_EMPTY_TAG,
        c.MUSTACH_ERROR_BAD_DELIMITER,
        c.MUSTACH_ERROR_TOO_DEEP,
        c.MUSTACH_ERROR_CLOSING,
        c.MUSTACH_ERROR_TOO_MUCH_NESTING,
        => |err| {
            log.debug("Uh oh! Error {any}\n", .{err});
            return error.CouldNotRenderTemplate;
        },
        c.MUSTACH_ERROR_USER(@intFromEnum(UserError.GetFailedForKey)) => {
            return error.CouldNotRenderTemplate;
        },
        // We've handled all other known mustach return codes
        else => {
            log.debug("{d}", .{return_val});
            unreachable;
        },
    }
}

fn getLucideIcon(key: []const u8) !?[]const u8 {
    if (mem.startsWith(u8, key, "lucide.")) {
        return lucide.icon(key["lucide.".len..]);
    }

    return null;
}

fn handleException(ctx: *c.JSContext) !noreturn {
    const exception = c.JS_GetException(ctx);
    defer c.JS_FreeValue(ctx, exception);

    const str = c.JS_ToCString(ctx, exception);
    defer c.JS_FreeCString(ctx, str);
    const error_message = mem.span(str);

    const stack = c.JS_GetPropertyStr(ctx, exception, "stack");
    defer c.JS_FreeValue(ctx, stack);

    const stack_str = c.JS_ToCString(ctx, stack);
    defer c.JS_FreeCString(ctx, stack_str);
    const stack_message = mem.span(stack_str);

    log.err("JS Exception: {s} {s}", .{ error_message, stack_message });

    return error.JSException;
}

const RenderComponentModel = struct {
    site_root: []const u8,
};

/// renderComponent will spin up a one-off QuickJS runtime and register some modules in a brand new context:
/// - htm
/// - vhtml
/// Then, it will load and execute the component source as a module, expecting it to export the following:
/// - render(): string
/// - style?: string
/// The render function will be called to produce the component html.
/// The style string, if present, will be stored in a hash map, keyed by the component source.
///
/// NOTE: renderComponent MUST write to the writer.
fn renderComponent(
    allocator: mem.Allocator,
    src: [:0]const u8,
    writer: anytype,
    component_assets: *ComponentAssets,
    model: RenderComponentModel,
) !void {
    const rt = c.JS_NewRuntime() orelse return error.CannotAllocateJSRuntime;
    defer c.JS_FreeRuntime(rt);
    c.JS_SetMemoryLimit(rt, 0x100_000);
    c.JS_SetMaxStackSize(rt, 0x200_000);

    const ctx = c.JS_NewContext(rt) orelse return error.CannotAllocateJSContext;
    defer c.JS_FreeContext(ctx);

    // TODO register htm.js as a module so the script can do
    // import htm from 'htm';
    // function h(type, props, ...children) { return { type, props, children }; }
    // const t = htm.bind(h);
    //
    // const html = t`<h1>Hello world</h1>`;

    // m = js_new_module_def(ctx, module_name_atom);
    // The module source is treated as the contents of an async function body, but return is not allowed.

    const htm_mod = c.JS_Eval(ctx, htm.mjs, htm.mjs.len, "htm", c.JS_EVAL_TYPE_MODULE);
    defer c.JS_FreeValue(ctx, htm_mod);
    switch (htm_mod.tag) {
        c.JS_TAG_EXCEPTION => try handleException(ctx),
        else => {},
    }

    const vhtml_mod = c.JS_Eval(ctx, vhtml.js, vhtml.js.len, "vhtml", c.JS_EVAL_TYPE_GLOBAL);
    defer c.JS_FreeValue(ctx, vhtml_mod);
    switch (vhtml_mod.tag) {
        c.JS_TAG_EXCEPTION => try handleException(ctx),
        else => {},
    }

    const hacky_mod_src = try fmt.allocPrint(allocator, "export const site_root = \"{[site_root]s}\";", .{ .site_root = model.site_root });
    defer allocator.free(hacky_mod_src);
    const hacky_mod_src_z = try allocator.dupeZ(u8, hacky_mod_src);
    defer allocator.free(hacky_mod_src_z);
    const hacky_mod = c.JS_Eval(ctx, hacky_mod_src_z, hacky_mod_src.len, "site", c.JS_EVAL_TYPE_MODULE);
    defer c.JS_FreeValue(ctx, hacky_mod);

    const hacky_mod_src2: [:0]const u8 =
        \\import htm from 'htm';
        \\export const html = htm.bind(globalThis.vhtml);
    ;
    const hacky_mod2 = c.JS_Eval(ctx, hacky_mod_src2, hacky_mod_src2.len, "goku", c.JS_EVAL_TYPE_MODULE);
    defer c.JS_FreeValue(ctx, hacky_mod2);

    const user_component_mod = c.JS_Eval(ctx, src, src.len, "component", c.JS_EVAL_TYPE_MODULE);
    defer c.JS_FreeValue(ctx, user_component_mod);
    switch (user_component_mod.tag) {
        c.JS_TAG_EXCEPTION => try handleException(ctx),
        else => {},
    }

    const t =
        \\import * as c from 'component';
        \\try {
        \\globalThis.html = c.render();
        \\} catch (e) {
        \\globalThis.html = e.message || 'Failed to render the component.';
        \\}
        \\if (c.style) globalThis.style = c.style;
        \\if (c.script) globalThis.script = c.script;
    ;
    const eval_result = c.JS_Eval(ctx, t, t.len, "<input>", c.JS_EVAL_TYPE_MODULE);
    defer c.JS_FreeValue(ctx, eval_result);
    switch (eval_result.tag) {
        c.JS_TAG_EXCEPTION => try handleException(ctx),
        else => {},
    }

    const global_object = c.JS_GetGlobalObject(ctx);
    defer c.JS_FreeValue(ctx, global_object);

    {
        const html = c.JS_GetPropertyStr(ctx, global_object, "html");
        defer c.JS_FreeValue(ctx, html);

        switch (html.tag) {
            c.JS_TAG_EXCEPTION => try handleException(ctx),
            else => return error.Huh,
            c.JS_TAG_STRING => {
                const str = c.JS_ToCString(ctx, html);
                defer c.JS_FreeCString(ctx, str);
                try writer.print("{s}", .{str});
            },
        }
    }

    style: {
        const style = c.JS_GetPropertyStr(ctx, global_object, "style");
        defer c.JS_FreeValue(ctx, style);

        switch (style.tag) {
            c.JS_TAG_EXCEPTION => try handleException(ctx),
            c.JS_TAG_STRING => {
                const result = try component_assets.style_map.getOrPut(component_assets.arena.allocator(), src);

                if (result.found_existing) break :style;

                const str = c.JS_ToCString(ctx, style);
                defer c.JS_FreeCString(ctx, str);

                const value: []const u8 = try component_assets.arena.allocator().dupe(
                    u8,
                    mem.span(str),
                );
                result.value_ptr.* = value;
            },
            else => {},
        }
    }

    script: {
        const script = c.JS_GetPropertyStr(ctx, global_object, "script");
        defer c.JS_FreeValue(ctx, script);

        switch (script.tag) {
            c.JS_TAG_EXCEPTION => try handleException(ctx),
            c.JS_TAG_STRING => {
                const result = try component_assets.script_map.getOrPut(component_assets.arena.allocator(), src);

                if (result.found_existing) break :script;

                const str = c.JS_ToCString(ctx, script);
                defer c.JS_FreeCString(ctx, str);
                const value = try component_assets.arena.allocator().dupe(
                    u8,
                    mem.span(str),
                );

                result.value_ptr.* = value;
            },
            else => {},
        }
    }
}
