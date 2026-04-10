const assets = @import("assets.zig");
const c = @import("c");
const debug = std.debug;
const log = std.log.scoped(.markdown);
const mem = std.mem;
const std = @import("std");
const testing = std.testing;

pub const Heading = struct {
    level: u8,
    id: []const u8,
    text: []const u8,
};

pub const BibliographyEntries = std.StringHashMap([]const u8);

pub const PreprocessedContent = struct {
    content: []const u8,
    requires_mustache: bool,

    pub fn deinit(self: PreprocessedContent, allocator: mem.Allocator) void {
        allocator.free(self.content);
    }
};

pub const Rendered = struct {
    html: []const u8,
    toc_html: []const u8,
    word_count: usize,
    has_math: bool,
    has_code: bool,

    pub fn deinit(self: Rendered, allocator: mem.Allocator) void {
        allocator.free(self.html);
        allocator.free(self.toc_html);
    }

    pub fn readingTimeMinutes(self: Rendered) usize {
        return @max(1, std.math.divCeil(usize, self.word_count, 250) catch 1);
    }
};

const MdBlockType = enum(c.MD_BLOCKTYPE) {
    doc = 0,
    quote = 1,
    ul = 2,
    ol = 3,
    li = 4,
    hr = 5,
    h = 6,
    code = 7,
    html = 8,
    p = 9,
    table = 10,
    thead = 11,
    tbody = 12,
    tr = 13,
    th = 14,
    td = 15,
    _,

    pub fn from(t: c.MD_BLOCKTYPE) MdBlockType {
        return @enumFromInt(t);
    }
};

pub const RenderStreamConfig = struct {
    url_prefix: ?[]const u8 = null,
    bibliography_entries: ?*const BibliographyEntries = null,
    asset_manifest: ?*const assets.Manifest = null,
};

pub fn renderAlloc(allocator: mem.Allocator, markdown: []const u8, config: RenderStreamConfig) !Rendered {
    const with_footnotes = try preprocessFootnotes(allocator, markdown);
    defer allocator.free(with_footnotes);

    const with_citations = try preprocessCitations(allocator, with_footnotes, config);
    defer allocator.free(with_citations);

    const with_directives = try preprocessDirectives(allocator, with_citations, config);
    defer allocator.free(with_directives);

    const preprocessed = try preprocessSidenotes(allocator, with_directives);
    defer allocator.free(preprocessed);

    var html_buf = std.ArrayList(u8).init(allocator);
    errdefer html_buf.deinit();

    var parser = try Parser.init(allocator, html_buf.writer().any(), config.url_prefix, config.asset_manifest);
    defer parser.deinit();

    const result = c.md_parse(
        @ptrCast(preprocessed),
        @as(c_uint, @intCast(preprocessed.len)),
        parser.parser(),
        parser.ptr(),
    );
    if (result != 0) return error.CouldNotTransformMarkdown;

    return .{
        .html = try html_buf.toOwnedSlice(),
        .toc_html = try parser.buildTocHtml(),
        .word_count = parser.word_count,
        .has_math = parser.has_math,
        .has_code = parser.has_code,
    };
}

pub fn renderStream(markdown: []const u8, config: RenderStreamConfig, writer: anytype) !void {
    const rendered = try renderAlloc(std.heap.page_allocator, markdown, config);
    defer rendered.deinit(std.heap.page_allocator);
    try writer.writeAll(rendered.html);
}

pub fn preprocessInteractiveFigures(allocator: mem.Allocator, markdown: []const u8) !PreprocessedContent {
    var arena = std.heap.ArenaAllocator.init(allocator);
    defer arena.deinit();

    var output = std.ArrayList(u8).init(arena.allocator());
    var lines = mem.splitScalar(u8, markdown, '\n');
    var in_fence = false;
    var requires_mustache = false;

    while (lines.next()) |line| {
        if (isFenceDelimiter(line)) {
            in_fence = !in_fence;
            try output.appendSlice(line);
            try output.append('\n');
            continue;
        }

        const trimmed = mem.trimLeft(u8, line, " \t");
        if (!in_fence and mem.startsWith(u8, trimmed, ":::interactive")) {
            const header = mem.trim(u8, trimmed[":::interactive".len..], " \t\r");
            if (header.len == 0) {
                try output.appendSlice(line);
                try output.append('\n');
                continue;
            }

            const first_space = mem.indexOfAny(u8, header, " \t") orelse header.len;
            const component_name = mem.trim(u8, header[0..first_space], " \t");
            const title = mem.trim(u8, header[first_space..], " \t");

            var caption = std.ArrayList(u8).init(arena.allocator());
            var found_close = false;
            while (lines.next()) |inner_line| {
                if (mem.eql(u8, mem.trim(u8, inner_line, " \t\r"), ":::")) {
                    found_close = true;
                    break;
                }
                if (caption.items.len > 0) try caption.append(' ');
                try caption.appendSlice(mem.trim(u8, inner_line, " \t\r"));
            }

            if (!found_close) {
                try output.appendSlice(line);
                try output.append('\n');
                try output.appendSlice(caption.items);
                break;
            }

            requires_mustache = true;
            try output.appendSlice("<figure class=\"interactive-figure\"><div class=\"interactive-figure-frame\">{{& component ");
            try output.appendSlice(component_name);
            try output.appendSlice("}}</div>");
            if (title.len > 0 or caption.items.len > 0) {
                try output.appendSlice("<figcaption>");
                if (title.len > 0) {
                    try output.appendSlice("<strong>");
                    try appendEscapedHtml(&output, title);
                    try output.appendSlice("</strong>");
                    if (caption.items.len > 0) try output.append(' ');
                }
                if (caption.items.len > 0) {
                    try appendEscapedHtml(&output, caption.items);
                }
                try output.appendSlice("</figcaption>");
            }
            try output.appendSlice("</figure>\n");
            continue;
        }

        try output.appendSlice(line);
        try output.append('\n');
    }

    return .{
        .content = try allocator.dupe(u8, output.items),
        .requires_mustache = requires_mustache,
    };
}

fn appendEscapedHtml(buf: *std.ArrayList(u8), text: []const u8) !void {
    for (text) |char| {
        switch (char) {
            '&' => try buf.appendSlice("&amp;"),
            '<' => try buf.appendSlice("&lt;"),
            '>' => try buf.appendSlice("&gt;"),
            '"' => try buf.appendSlice("&quot;"),
            else => try buf.append(char),
        }
    }
}

fn isFenceDelimiter(line: []const u8) bool {
    const trimmed = mem.trimLeft(u8, line, " \t");
    return mem.startsWith(u8, trimmed, "```") or mem.startsWith(u8, trimmed, "~~~");
}

fn preprocessFootnotes(allocator: mem.Allocator, markdown: []const u8) ![]const u8 {
    var arena = std.heap.ArenaAllocator.init(allocator);
    defer arena.deinit();

    var definitions = std.StringHashMap([]const u8).init(arena.allocator());
    var content = std.ArrayList(u8).init(arena.allocator());
    var current_id: ?[]const u8 = null;
    var current_text = std.ArrayList(u8).init(arena.allocator());

    const Helpers = struct {
        fn flushDefinition(
            defs: *std.StringHashMap([]const u8),
            id: *?[]const u8,
            text: *std.ArrayList(u8),
        ) !void {
            if (id.*) |current| {
                try defs.put(current, try text.toOwnedSlice());
                id.* = null;
                text.* = std.ArrayList(u8).init(text.allocator);
            }
        }

        fn parseDefinitionStart(line: []const u8) ?struct { id: []const u8, body: []const u8 } {
            if (!mem.startsWith(u8, line, "[^")) return null;
            const closing = mem.indexOfScalar(u8, line, ']') orelse return null;
            if (closing + 1 >= line.len or line[closing + 1] != ':') return null;
            return .{
                .id = line[2..closing],
                .body = mem.trimLeft(u8, line[closing + 2 ..], " "),
            };
        }

        fn isContinuation(line: []const u8) bool {
            return mem.startsWith(u8, line, "    ") or mem.startsWith(u8, line, "\t");
        }

        fn sanitizeId(arena_allocator: mem.Allocator, raw: []const u8) ![]const u8 {
            var buf = std.ArrayList(u8).init(arena_allocator);
            var last_dash = false;
            for (raw) |char| {
                if (std.ascii.isAlphanumeric(char)) {
                    try buf.append(std.ascii.toLower(char));
                    last_dash = false;
                } else if (!last_dash and buf.items.len > 0) {
                    try buf.append('-');
                    last_dash = true;
                }
            }
            if (buf.items.len == 0) try buf.appendSlice("footnote");
            return try buf.toOwnedSlice();
        }
    };

    var lines = mem.splitScalar(u8, markdown, '\n');
    while (lines.next()) |line| {
        if (Helpers.parseDefinitionStart(line)) |definition| {
            try Helpers.flushDefinition(&definitions, &current_id, &current_text);
            current_id = try arena.allocator().dupe(u8, definition.id);
            if (definition.body.len > 0) {
                try current_text.appendSlice(definition.body);
            }
            continue;
        }

        if (current_id != null and Helpers.isContinuation(line)) {
            if (current_text.items.len > 0) try current_text.append('\n');
            const trimmed = if (line[0] == '\t') line[1..] else line[4..];
            try current_text.appendSlice(trimmed);
            continue;
        }

        try Helpers.flushDefinition(&definitions, &current_id, &current_text);
        try content.appendSlice(line);
        try content.append('\n');
    }
    try Helpers.flushDefinition(&definitions, &current_id, &current_text);

    var ref_numbers = std.StringHashMap(usize).init(arena.allocator());
    var ordered_ids = std.ArrayList([]const u8).init(arena.allocator());
    var output = std.ArrayList(u8).init(arena.allocator());

    var index: usize = 0;
    while (index < content.items.len) {
        if (index + 3 < content.items.len and content.items[index] == '[' and content.items[index + 1] == '^') {
            if (mem.indexOfScalarPos(u8, content.items, index + 2, ']')) |end_index| {
                const raw_id = content.items[index + 2 .. end_index];
                if (definitions.get(raw_id)) |_| {
                    const gop = try ref_numbers.getOrPut(raw_id);
                    if (!gop.found_existing) {
                        gop.value_ptr.* = ordered_ids.items.len + 1;
                        try ordered_ids.append(raw_id);
                    }
                    const safe_id = try Helpers.sanitizeId(arena.allocator(), raw_id);
                    try output.writer().print(
                        "<sup id=\"fnref:{s}\"><a href=\"#fn:{s}\" class=\"footnote-ref\">{d}</a></sup>",
                        .{ safe_id, safe_id, gop.value_ptr.* },
                    );
                    index = end_index + 1;
                    continue;
                }
            }
        }

        try output.append(content.items[index]);
        index += 1;
    }

    if (ordered_ids.items.len > 0) {
        try output.appendSlice("\n\n---\n\n");
        for (ordered_ids.items, 0..) |raw_id, ordinal| {
            const safe_id = try Helpers.sanitizeId(arena.allocator(), raw_id);
            const body = definitions.get(raw_id).?;
            var body_lines = mem.splitScalar(u8, body, '\n');
            const first_line = body_lines.next() orelse "";
            try output.writer().print("{d}. <span id=\"fn:{s}\"></span> {s}", .{ ordinal + 1, safe_id, first_line });
            while (body_lines.next()) |body_line| {
                try output.appendSlice("\n    ");
                try output.appendSlice(body_line);
            }
            try output.writer().print(" [↩](#fnref:{s})\n", .{safe_id});
        }
    }

    return try allocator.dupe(u8, output.items);
}

fn preprocessCitations(allocator: mem.Allocator, markdown: []const u8, config: RenderStreamConfig) ![]const u8 {
    var arena = std.heap.ArenaAllocator.init(allocator);
    defer arena.deinit();

    var definitions = std.StringHashMap([]const u8).init(arena.allocator());
    var content = std.ArrayList(u8).init(arena.allocator());
    var current_id: ?[]const u8 = null;
    var current_text = std.ArrayList(u8).init(arena.allocator());

    const Helpers = struct {
        fn flushDefinition(
            defs: *std.StringHashMap([]const u8),
            id: *?[]const u8,
            text: *std.ArrayList(u8),
        ) !void {
            if (id.*) |current| {
                try defs.put(current, try text.toOwnedSlice());
                id.* = null;
                text.* = std.ArrayList(u8).init(text.allocator);
            }
        }

        fn parseDefinitionStart(line: []const u8) ?struct { id: []const u8, body: []const u8 } {
            if (!mem.startsWith(u8, line, "[@")) return null;
            const closing = mem.indexOfScalar(u8, line, ']') orelse return null;
            if (closing + 1 >= line.len or line[closing + 1] != ':') return null;
            return .{
                .id = line[2..closing],
                .body = mem.trimLeft(u8, line[closing + 2 ..], " "),
            };
        }

        fn isContinuation(line: []const u8) bool {
            return mem.startsWith(u8, line, "    ") or mem.startsWith(u8, line, "\t");
        }

        fn sanitizeId(arena_allocator: mem.Allocator, raw: []const u8) ![]const u8 {
            var buf = std.ArrayList(u8).init(arena_allocator);
            var last_dash = false;
            for (raw) |char| {
                if (std.ascii.isAlphanumeric(char)) {
                    try buf.append(std.ascii.toLower(char));
                    last_dash = false;
                } else if (!last_dash and buf.items.len > 0) {
                    try buf.append('-');
                    last_dash = true;
                }
            }
            if (buf.items.len == 0) try buf.appendSlice("citation");
            return try buf.toOwnedSlice();
        }

        fn parseCitationIds(arena_allocator: mem.Allocator, body: []const u8) !?[][]const u8 {
            var ids = std.ArrayList([]const u8).init(arena_allocator);
            var splitter = mem.splitSequence(u8, body, ";");
            while (splitter.next()) |part| {
                const trimmed = mem.trim(u8, part, " \n\t\r");
                if (trimmed.len < 2 or trimmed[0] != '@') return null;
                try ids.append(trimmed[1..]);
            }
            if (ids.items.len == 0) return null;
            return try ids.toOwnedSlice();
        }
    };

    var lines = mem.splitScalar(u8, markdown, '\n');
    while (lines.next()) |line| {
        if (Helpers.parseDefinitionStart(line)) |definition| {
            try Helpers.flushDefinition(&definitions, &current_id, &current_text);
            current_id = try arena.allocator().dupe(u8, definition.id);
            if (definition.body.len > 0) {
                try current_text.appendSlice(definition.body);
            }
            continue;
        }

        if (current_id != null and Helpers.isContinuation(line)) {
            if (current_text.items.len > 0) try current_text.append('\n');
            const trimmed = if (line[0] == '\t') line[1..] else line[4..];
            try current_text.appendSlice(trimmed);
            continue;
        }

        try Helpers.flushDefinition(&definitions, &current_id, &current_text);
        try content.appendSlice(line);
        try content.append('\n');
    }
    try Helpers.flushDefinition(&definitions, &current_id, &current_text);

    var ref_numbers = std.StringHashMap(usize).init(arena.allocator());
    var ordered_ids = std.ArrayList([]const u8).init(arena.allocator());
    var output = std.ArrayList(u8).init(arena.allocator());

    var index: usize = 0;
    while (index < content.items.len) {
        if (index + 3 < content.items.len and content.items[index] == '[' and content.items[index + 1] == '@') {
            if (mem.indexOfScalarPos(u8, content.items, index + 2, ']')) |end_index| {
                const raw_group = content.items[index + 1 .. end_index];
                if (try Helpers.parseCitationIds(arena.allocator(), raw_group)) |cite_ids| {
                    var all_present = true;
                    for (cite_ids) |cite_id| {
                        if (definitions.get(cite_id) == null and (config.bibliography_entries == null or config.bibliography_entries.?.get(cite_id) == null)) {
                            all_present = false;
                            break;
                        }
                    }

                    if (all_present) {
                        try output.appendSlice("<span class=\"citation-group\">[");
                        for (cite_ids, 0..) |cite_id, cite_index| {
                            const gop = try ref_numbers.getOrPut(cite_id);
                            if (!gop.found_existing) {
                                gop.value_ptr.* = ordered_ids.items.len + 1;
                                try ordered_ids.append(cite_id);
                            }
                            const safe_id = try Helpers.sanitizeId(arena.allocator(), cite_id);
                            if (cite_index > 0) try output.appendSlice("; ");
                            try output.writer().print(
                                "<a href=\"#cite:{s}\" class=\"citation-ref\">{d}</a>",
                                .{ safe_id, gop.value_ptr.* },
                            );
                        }
                        try output.appendSlice("]</span>");
                        index = end_index + 1;
                        continue;
                    }
                }
            }
        }

        try output.append(content.items[index]);
        index += 1;
    }

    if (ordered_ids.items.len > 0) {
        try output.appendSlice("\n\n## References\n\n");
        for (ordered_ids.items, 0..) |raw_id, ordinal| {
            const safe_id = try Helpers.sanitizeId(arena.allocator(), raw_id);
            const body = definitions.get(raw_id) orelse config.bibliography_entries.?.get(raw_id).?;
            var body_lines = mem.splitScalar(u8, body, '\n');
            const first_line = body_lines.next() orelse "";
            try output.writer().print("{d}. <span id=\"cite:{s}\"></span> {s}\n", .{ ordinal + 1, safe_id, first_line });
            while (body_lines.next()) |body_line| {
                try output.appendSlice("    ");
                try output.appendSlice(body_line);
                try output.append('\n');
            }
        }
    }

    return try allocator.dupe(u8, output.items);
}

fn preprocessDirectives(allocator: mem.Allocator, markdown: []const u8, config: RenderStreamConfig) anyerror![]const u8 {
    var arena = std.heap.ArenaAllocator.init(allocator);
    defer arena.deinit();

    var output = std.ArrayList(u8).init(arena.allocator());
    var lines = mem.splitScalar(u8, markdown, '\n');
    var in_fence = false;

    const Helpers = struct {
        fn isSupportedDirective(kind: []const u8) bool {
            return mem.eql(u8, kind, "note") or
                mem.eql(u8, kind, "tip") or
                mem.eql(u8, kind, "info") or
                mem.eql(u8, kind, "warning") or
                mem.eql(u8, kind, "important") or
                mem.eql(u8, kind, "caution") or
                mem.eql(u8, kind, "details") or
                mem.eql(u8, kind, "figure") or
                mem.eql(u8, kind, "margin-figure");
        }

        fn defaultTitle(kind: []const u8) []const u8 {
            if (mem.eql(u8, kind, "note")) return "Note";
            if (mem.eql(u8, kind, "tip")) return "Tip";
            if (mem.eql(u8, kind, "info")) return "Info";
            if (mem.eql(u8, kind, "warning")) return "Warning";
            if (mem.eql(u8, kind, "important")) return "Important";
            if (mem.eql(u8, kind, "caution")) return "Caution";
            if (mem.eql(u8, kind, "details")) return "Details";
            if (mem.eql(u8, kind, "figure")) return "Figure";
            if (mem.eql(u8, kind, "margin-figure")) return "Margin figure";
            return "Block";
        }
    };

    while (lines.next()) |line| {
        if (isFenceDelimiter(line)) {
            in_fence = !in_fence;
            try output.appendSlice(line);
            try output.append('\n');
            continue;
        }

        const trimmed = mem.trimLeft(u8, line, " \t");
        if (!in_fence and mem.startsWith(u8, trimmed, ":::")) {
            const header = mem.trim(u8, trimmed[3..], " \t\r");
            if (header.len == 0) {
                try output.appendSlice(line);
                try output.append('\n');
                continue;
            }

            const first_space = mem.indexOfAny(u8, header, " \t") orelse header.len;
            const kind = header[0..first_space];
            if (!Helpers.isSupportedDirective(kind)) {
                try output.appendSlice(line);
                try output.append('\n');
                continue;
            }

            const title = mem.trim(u8, header[first_space..], " \t");
            var body = std.ArrayList(u8).init(arena.allocator());
            var found_close = false;
            while (lines.next()) |inner_line| {
                if (mem.eql(u8, mem.trim(u8, inner_line, " \t\r"), ":::")) {
                    found_close = true;
                    break;
                }
                try body.appendSlice(inner_line);
                try body.append('\n');
            }

            if (!found_close) {
                try output.appendSlice(line);
                try output.append('\n');
                try output.appendSlice(body.items);
                break;
            }

            const rendered_body = try renderAlloc(allocator, body.items, config);
            defer rendered_body.deinit(allocator);

            if (mem.eql(u8, kind, "details")) {
                try output.appendSlice("<details class=\"details-block\"><summary>");
                try appendEscapedHtml(&output, if (title.len > 0) title else Helpers.defaultTitle(kind));
                try output.appendSlice("</summary>");
                try output.appendSlice(rendered_body.html);
                try output.appendSlice("</details>\n");
            } else if (mem.eql(u8, kind, "figure") or mem.eql(u8, kind, "margin-figure")) {
                const class_name = if (mem.eql(u8, kind, "margin-figure")) "margin-figure" else "article-figure";
                try output.writer().print("<figure class=\"{s}\">", .{class_name});
                try output.appendSlice(rendered_body.html);
                if (title.len > 0) {
                    try output.appendSlice("<figcaption>");
                    try appendEscapedHtml(&output, title);
                    try output.appendSlice("</figcaption>");
                }
                try output.appendSlice("</figure>\n");
            } else {
                try output.writer().print("<div class=\"admonition admonition-{s}\"><p class=\"admonition-title\">", .{kind});
                try appendEscapedHtml(&output, if (title.len > 0) title else Helpers.defaultTitle(kind));
                try output.appendSlice("</p>");
                try output.appendSlice(rendered_body.html);
                try output.appendSlice("</div>\n");
            }

            continue;
        }

        try output.appendSlice(line);
        try output.append('\n');
    }

    return try allocator.dupe(u8, output.items);
}

fn preprocessSidenotes(allocator: mem.Allocator, markdown: []const u8) ![]const u8 {
    var arena = std.heap.ArenaAllocator.init(allocator);
    defer arena.deinit();

    var output = std.ArrayList(u8).init(arena.allocator());
    var lines = mem.splitScalar(u8, markdown, '\n');
    var in_fence = false;
    var sidenote_number: usize = 0;

    while (lines.next()) |line| {
        if (isFenceDelimiter(line)) {
            in_fence = !in_fence;
            try output.appendSlice(line);
            try output.append('\n');
            continue;
        }

        if (in_fence) {
            try output.appendSlice(line);
            try output.append('\n');
            continue;
        }

        var last_index: usize = 0;
        var index: usize = 0;
        while (index + 1 < line.len) {
            if (line[index] == '^' and line[index + 1] == '[') {
                const end_index = mem.indexOfScalarPos(u8, line, index + 2, ']') orelse break;
                sidenote_number += 1;
                try output.appendSlice(line[last_index..index]);
                try output.writer().print("<span class=\"sidenote\"><sup class=\"sidenote-number\">{d}</sup><span class=\"sidenote-body\">", .{sidenote_number});
                try appendEscapedHtml(&output, line[index + 2 .. end_index]);
                try output.appendSlice("</span></span>");
                index = end_index + 1;
                last_index = index;
                continue;
            }
            index += 1;
        }

        try output.appendSlice(line[last_index..]);
        try output.append('\n');
    }

    return try allocator.dupe(u8, output.items);
}

const Parser = struct {
    allocator: mem.Allocator,
    writer: std.io.AnyWriter,
    url_prefix: ?[]const u8,
    asset_manifest: ?*const assets.Manifest,
    image_nesting_level: u8 = 0,
    current_heading_level: ?u8 = null,
    heading_output_buf: std.ArrayList(u8),
    heading_text_buf: std.ArrayList(u8),
    headings: std.ArrayList(Heading),
    heading_id_counts: std.StringHashMapUnmanaged(u32) = .empty,
    word_count: usize = 0,
    has_math: bool = false,
    has_code: bool = false,
    _parser: c.MD_PARSER = .{
        .abi_version = 0,
        .flags = c.MD_FLAG_STRIKETHROUGH | c.MD_FLAG_LATEXMATHSPANS | c.MD_FLAG_UNDERLINE,
        .enter_block = enter_block,
        .leave_block = leave_block,
        .enter_span = enter_span,
        .leave_span = leave_span,
        .text = text,
        .debug_log = debug_log,
        .syntax = null,
    },

    fn init(allocator: mem.Allocator, writer: std.io.AnyWriter, url_prefix: ?[]const u8, asset_manifest: ?*const assets.Manifest) !Parser {
        return .{
            .allocator = allocator,
            .writer = writer,
            .url_prefix = url_prefix,
            .asset_manifest = asset_manifest,
            .heading_output_buf = std.ArrayList(u8).init(allocator),
            .heading_text_buf = std.ArrayList(u8).init(allocator),
            .headings = std.ArrayList(Heading).init(allocator),
        };
    }

    fn resolveAssetPath(self: *Parser, path: []const u8) !?[]const u8 {
        if (!mem.startsWith(u8, path, "/assets/")) return null;
        const manifest = self.asset_manifest orelse return null;
        const logical_path = path["/assets/".len..];
        const hashed = manifest.get(logical_path) orelse return null;
        return try std.fmt.allocPrint(self.allocator, "/{s}", .{hashed});
    }

    fn resolveOutputPath(self: *Parser, path: []const u8) ![]const u8 {
        const manifest_path = try self.resolveAssetPath(path);
        const base = manifest_path orelse path;
        if (mem.startsWith(u8, base, "/")) {
            if (self.url_prefix) |prefix| {
                defer if (manifest_path) |owned| self.allocator.free(owned);
                return try std.fmt.allocPrint(self.allocator, "{s}{s}", .{ prefix, base });
            }
        }
        if (manifest_path) |owned| return owned;
        return try self.allocator.dupe(u8, base);
    }

    fn deinit(self: *Parser) void {
        for (self.headings.items) |heading| {
            self.allocator.free(heading.id);
            self.allocator.free(heading.text);
        }
        self.headings.deinit();

        var it = self.heading_id_counts.iterator();
        while (it.next()) |entry| {
            self.allocator.free(entry.key_ptr.*);
        }
        self.heading_id_counts.deinit(self.allocator);

        self.heading_output_buf.deinit();
        self.heading_text_buf.deinit();
    }

    fn parser(self: *const Parser) *const c.MD_PARSER {
        return &self._parser;
    }

    fn ptr(self: *const Parser) ?*anyopaque {
        return @constCast(@ptrCast(self));
    }

    fn fromPtr(userdata: ?*anyopaque) *Parser {
        return @ptrCast(@alignCast(userdata));
    }

    fn writeAll(self: *Parser, bytes: []const u8) !void {
        if (self.current_heading_level != null) {
            try self.heading_output_buf.appendSlice(bytes);
        } else {
            try self.writer.writeAll(bytes);
        }
    }

    fn writeByte(self: *Parser, byte: u8) !void {
        if (self.current_heading_level != null) {
            try self.heading_output_buf.append(byte);
        } else {
            try self.writer.writeByte(byte);
        }
    }

    fn print(self: *Parser, comptime format: []const u8, args: anytype) !void {
        const rendered = try std.fmt.allocPrint(self.allocator, format, args);
        defer self.allocator.free(rendered);
        try self.writeAll(rendered);
    }

    fn countWords(self: *Parser, text_buf: []const u8) void {
        var it = mem.tokenizeAny(u8, text_buf, " \n\t\r");
        while (it.next() != null) self.word_count += 1;
    }

    fn slugify(self: *Parser, text_buf: []const u8) ![]const u8 {
        var slug_buf = std.ArrayList(u8).init(self.allocator);
        errdefer slug_buf.deinit();

        var last_dash = false;
        for (text_buf) |char| {
            if (std.ascii.isAlphanumeric(char)) {
                try slug_buf.append(std.ascii.toLower(char));
                last_dash = false;
            } else if (!last_dash and slug_buf.items.len > 0) {
                try slug_buf.append('-');
                last_dash = true;
            }
        }

        while (slug_buf.items.len > 0 and slug_buf.items[slug_buf.items.len - 1] == '-') {
            _ = slug_buf.pop();
        }

        if (slug_buf.items.len == 0) try slug_buf.appendSlice("section");

        const base_slug = try slug_buf.toOwnedSlice();
        errdefer self.allocator.free(base_slug);

        const gop = try self.heading_id_counts.getOrPut(self.allocator, base_slug);
        if (!gop.found_existing) {
            gop.key_ptr.* = try self.allocator.dupe(u8, base_slug);
            gop.value_ptr.* = 1;
            return base_slug;
        }

        const current_count = gop.value_ptr.*;
        gop.value_ptr.* += 1;
        self.allocator.free(base_slug);
        return try std.fmt.allocPrint(self.allocator, "{s}-{d}", .{ gop.key_ptr.*, current_count });
    }

    fn buildTocHtml(self: *Parser) ![]const u8 {
        if (self.headings.items.len == 0) return try self.allocator.dupe(u8, "");

        var buf = std.ArrayList(u8).init(self.allocator);
        errdefer buf.deinit();

        try buf.appendSlice("<nav class=\"table-of-contents\"><p class=\"menu-label\">Contents</p><ul class=\"menu-list\">");
        for (self.headings.items) |heading| {
            try buf.writer().print(
                "<li class=\"toc-level-{d}\"><a href=\"#{s}\">{s}</a></li>",
                .{ heading.level, heading.id, heading.text },
            );
        }
        try buf.appendSlice("</ul></nav>");
        return try buf.toOwnedSlice();
    }

    fn debug_log(buf: [*c]const u8, userdata: ?*anyopaque) callconv(.C) void {
        const self = fromPtr(userdata);
        const msg = mem.sliceTo(buf, 0);
        self.writer.print("{s}\n", .{msg}) catch @panic("Could not debug markdown parser");
    }

    fn text(kind: c.MD_TEXTTYPE, buf: [*c]const c.MD_CHAR, len: c.MD_SIZE, userdata: ?*anyopaque) callconv(.C) c_int {
        const self = fromPtr(userdata);
        const out = buf[0..len];

        switch (kind) {
            c.MD_TEXT_NULLCHAR => {},
            c.MD_TEXT_BR => self.writeAll(if (self.image_nesting_level == 0) "<br>" else " ") catch return -1,
            c.MD_TEXT_SOFTBR => self.writeAll(if (self.image_nesting_level == 0) "\n" else " ") catch return -1,
            c.MD_TEXT_ENTITY => {
                if (self.image_nesting_level > 0) {
                    self.renderEscapedAttributeCurrent(out) catch return -1;
                } else {
                    self.renderEscapedCurrent(out) catch return -1;
                }
            },
            c.MD_TEXT_HTML => self.writeAll(out) catch return -1,
            c.MD_TEXT_LATEXMATH => {
                self.has_math = true;
                self.writeAll(out) catch return -1;
            },
            c.MD_TEXT_NORMAL,
            c.MD_TEXT_CODE,
            => {
                if (self.image_nesting_level > 0) {
                    self.renderEscapedAttributeCurrent(out) catch return -1;
                } else {
                    self.renderEscapedCurrent(out) catch return -1;
                    self.countWords(out);
                    if (self.current_heading_level != null) {
                        self.heading_text_buf.appendSlice(out) catch return -1;
                    }
                }
            },
            else => unreachable,
        }

        return 0;
    }

    fn renderEscaped(buf: []const u8, writer: std.io.AnyWriter) !void {
        for (buf) |byte| {
            switch (byte) {
                '&' => try writer.writeAll("&amp;"),
                '<' => try writer.writeAll("&lt;"),
                '>' => try writer.writeAll("&gt;"),
                else => try writer.writeByte(byte),
            }
        }
    }

    fn renderEscapedCurrent(self: *Parser, buf: []const u8) !void {
        for (buf) |byte| {
            switch (byte) {
                '&' => try self.writeAll("&amp;"),
                '<' => try self.writeAll("&lt;"),
                '>' => try self.writeAll("&gt;"),
                else => try self.writeByte(byte),
            }
        }
    }

    fn renderEscapedAttribute(buf: []const u8, writer: std.io.AnyWriter) !void {
        for (buf) |byte| {
            switch (byte) {
                '&' => try writer.writeAll("&amp;"),
                '"' => try writer.writeAll("&quot;"),
                '<' => try writer.writeAll("&lt;"),
                '>' => try writer.writeAll("&gt;"),
                else => try writer.writeByte(byte),
            }
        }
    }

    fn renderEscapedAttributeCurrent(self: *Parser, buf: []const u8) !void {
        for (buf) |byte| {
            switch (byte) {
                '&' => try self.writeAll("&amp;"),
                '"' => try self.writeAll("&quot;"),
                '<' => try self.writeAll("&lt;"),
                '>' => try self.writeAll("&gt;"),
                else => try self.writeByte(byte),
            }
        }
    }

    fn writeAttribute(writer: std.io.AnyWriter, name: []const u8, value: []const u8) !void {
        try writer.print("{s}=\"", .{name});
        try renderEscapedAttribute(value, writer);
        try writer.writeAll("\" ");
    }

    fn writeAttributeCurrent(self: *Parser, name: []const u8, value: []const u8) !void {
        try self.print("{s}=\"", .{name});
        try self.renderEscapedAttributeCurrent(value);
        try self.writeAll("\" ");
    }

    fn enter_block(kind: c.MD_BLOCKTYPE, detail_ptr: ?*anyopaque, userdata: ?*anyopaque) callconv(.C) c_int {
        const self = fromPtr(userdata);

        switch (MdBlockType.from(kind)) {
            .doc => {},
            .quote => self.writeAll("<blockquote>\n") catch return -1,
            .ul => self.writeAll("<ul>\n") catch return -1,
            .ol => self.writeAll("<ol>\n") catch return -1,
            .li => self.writeAll("<li>\n") catch return -1,
            .hr => self.writeAll("<hr>\n") catch return -1,
            .h => {
                const detail: *c.MD_BLOCK_H_DETAIL = @ptrCast(@alignCast(detail_ptr));
                debug.assert(detail.level != 1);
                self.current_heading_level = @intCast(detail.level);
                self.heading_output_buf.clearRetainingCapacity();
                self.heading_text_buf.clearRetainingCapacity();
            },
            .code => {
                const detail: *c.MD_BLOCK_CODE_DETAIL = @ptrCast(@alignCast(detail_ptr));
                self.has_code = true;
                if (detail.lang.text != null and detail.lang.size > 0) {
                    const lang = detail.lang.text[0..detail.lang.size];
                    self.print("<pre><code class=\"language-{s}\">", .{lang}) catch return -1;
                } else {
                    self.writeAll("<pre><code>") catch return -1;
                }
            },
            .html => {},
            .p => self.writeAll("<p>\n") catch return -1,
            .table => self.writeAll("<table>\n") catch return -1,
            .thead => self.writeAll("<thead>\n") catch return -1,
            .tbody => self.writeAll("<tbody>\n") catch return -1,
            .tr => self.writeAll("<tr>\n") catch return -1,
            .th => self.writeAll("<th>\n") catch return -1,
            .td => self.writeAll("<td>\n") catch return -1,
            else => unreachable,
        }

        return 0;
    }

    fn leave_block(kind: c.MD_BLOCKTYPE, detail_ptr: ?*anyopaque, userdata: ?*anyopaque) callconv(.C) c_int {
        const self = fromPtr(userdata);

        switch (MdBlockType.from(kind)) {
            .doc => {},
            .quote => self.writeAll("</blockquote>\n") catch return -1,
            .ul => self.writeAll("</ul>\n") catch return -1,
            .ol => self.writeAll("</ol>") catch return -1,
            .li => self.writeAll("</li>") catch return -1,
            .hr => {},
            .h => {
                const detail: *c.MD_BLOCK_H_DETAIL = @ptrCast(@alignCast(detail_ptr));
                const heading_text = self.allocator.dupe(u8, mem.trim(u8, self.heading_text_buf.items, " \n\t\r")) catch return -1;
                errdefer self.allocator.free(heading_text);
                const heading_id = self.slugify(heading_text) catch return -1;
                errdefer self.allocator.free(heading_id);
                const heading_html = self.allocator.dupe(u8, self.heading_output_buf.items) catch return -1;
                defer self.allocator.free(heading_html);

                self.current_heading_level = null;
                self.print("<h{d} id=\"{s}\">{s}</h{d}>\n", .{ detail.level, heading_id, heading_html, detail.level }) catch return -1;
                self.headings.append(.{ .level = @intCast(detail.level), .id = heading_id, .text = heading_text }) catch return -1;
            },
            .code => self.writeAll("</code></pre>") catch return -1,
            .html => {},
            .p => self.writeAll("</p>") catch return -1,
            .table => self.writeAll("</table>") catch return -1,
            .thead => self.writeAll("</thead>") catch return -1,
            .tbody => self.writeAll("</tbody>") catch return -1,
            .tr => self.writeAll("</tr>") catch return -1,
            .th => self.writeAll("</th>") catch return -1,
            .td => self.writeAll("</td>") catch return -1,
            else => unreachable,
        }

        return 0;
    }

    fn enter_span(kind: c.MD_SPANTYPE, detail_ptr: ?*anyopaque, userdata: ?*anyopaque) callconv(.C) c_int {
        const self = fromPtr(userdata);
        switch (kind) {
            c.MD_SPAN_A => {
                const detail: *c.MD_SPAN_A_DETAIL = @ptrCast(@alignCast(detail_ptr));
                const href = detail.href.text[0..detail.href.size];
                const resolved = self.resolveOutputPath(href) catch return -1;
                defer self.allocator.free(resolved);
                self.print("<a href=\"{s}\">", .{resolved}) catch return -1;
            },
            c.MD_SPAN_CODE => {
                self.has_code = true;
                self.writeAll("<code>") catch return -1;
            },
            c.MD_SPAN_DEL => self.writeAll("<del>") catch return -1,
            c.MD_SPAN_EM => self.writeAll("<em>") catch return -1,
            c.MD_SPAN_IMG => {
                const detail: *c.MD_SPAN_IMG_DETAIL = @ptrCast(@alignCast(detail_ptr));
                const title: ?[]const u8 = if (detail.title.text == null) null else detail.title.text[0..detail.title.size];
                const src: ?[]const u8 = if (detail.src.text == null) null else detail.src.text[0..detail.src.size];

                self.image_nesting_level += 1;

                if (title != null) self.writeAll("<figure>") catch return -1;

                self.writeAll("<img ") catch return -1;
                if (title) |caption| self.writeAttributeCurrent("title", caption) catch return -1;
                if (src) |path| {
                    const resolved = self.resolveOutputPath(path) catch return -1;
                    defer self.allocator.free(resolved);
                    self.writeAttributeCurrent("src", resolved) catch return -1;
                }
                self.writeAll("alt=\"") catch return -1;
            },
            c.MD_SPAN_STRONG => self.writeAll("<strong>") catch return -1,
            c.MD_SPAN_U => self.writeAll("<u>") catch return -1,
            c.MD_SPAN_LATEXMATH => {
                self.has_math = true;
                self.writeAll("\\(") catch return -1;
            },
            c.MD_SPAN_LATEXMATH_DISPLAY => {
                self.has_math = true;
                self.writeAll("\\[") catch return -1;
            },
            c.MD_SPAN_WIKILINK => log.debug("Goku doesn't currently support rendering wikilinks.", .{}),
            else => unreachable,
        }

        return 0;
    }

    fn leave_span(kind: c.MD_SPANTYPE, detail_ptr: ?*anyopaque, userdata: ?*anyopaque) callconv(.C) c_int {
        const self = fromPtr(userdata);

        switch (kind) {
            c.MD_SPAN_A => self.writeAll("</a>") catch return -1,
            c.MD_SPAN_CODE => self.writeAll("</code>") catch return -1,
            c.MD_SPAN_DEL => self.writeAll("</del>") catch return -1,
            c.MD_SPAN_EM => self.writeAll("</em>") catch return -1,
            c.MD_SPAN_IMG => {
                const detail: *c.MD_SPAN_IMG_DETAIL = @ptrCast(@alignCast(detail_ptr));
                const title: ?[]const u8 = if (detail.title.text == null) null else detail.title.text[0..detail.title.size];

                self.image_nesting_level -= 1;
                self.writeAll("\" />") catch return -1;

                if (title) |caption| {
                    self.writeAll("<figcaption>") catch return -1;
                    self.renderEscapedCurrent(caption) catch return -1;
                    self.writeAll("</figcaption></figure>") catch return -1;
                }
            },
            c.MD_SPAN_STRONG => self.writeAll("</strong>") catch return -1,
            c.MD_SPAN_U => self.writeAll("</u>") catch return -1,
            c.MD_SPAN_LATEXMATH => self.writeAll("\\)") catch return -1,
            c.MD_SPAN_LATEXMATH_DISPLAY => self.writeAll("\\]") catch return -1,
            c.MD_SPAN_WIKILINK => log.debug("Goku doesn't currently support rendering wikilinks.", .{}),
            else => unreachable,
        }

        return 0;
    }
};

test "renderStream renders emphasis, deletion, underline, and math" {
    var buf = std.ArrayList(u8).init(testing.allocator);
    defer buf.deinit();

    try renderStream(
        "This has *emphasis*, ~~deletion~~, <u>html underline</u>, and $x^2 + y^2$.",
        .{},
        buf.writer(),
    );

    try testing.expectEqualStrings(
        "<p>\nThis has <em>emphasis</em>, <del>deletion</del>, <u>html underline</u>, and \\(x^2 + y^2\\).</p>",
        buf.items,
    );
}

test "renderStream renders image alt text and figcaption" {
    var buf = std.ArrayList(u8).init(testing.allocator);
    defer buf.deinit();

    try renderStream(
        "![A sample image](/images/example.png \"An example caption\")",
        .{ .url_prefix = "/blog" },
        buf.writer(),
    );

    try testing.expectEqualStrings(
        "<p>\n<figure><img title=\"An example caption\" src=\"/blog/images/example.png\" alt=\"A sample image\" /><figcaption>An example caption</figcaption></figure></p>",
        buf.items,
    );
}

test "renderAlloc emits heading ids and toc" {
    const rendered = try renderAlloc(testing.allocator, "## Intro\n\n### Details", .{});
    defer rendered.deinit(testing.allocator);

    try testing.expectEqualStrings(
        "<h2 id=\"intro\">Intro</h2>\n<h3 id=\"details\">Details</h3>\n",
        rendered.html,
    );
    try testing.expect(std.mem.indexOf(u8, rendered.toc_html, "#intro") != null);
    try testing.expect(std.mem.indexOf(u8, rendered.toc_html, "#details") != null);
}

test "renderAlloc renders footnotes" {
    const rendered = try renderAlloc(
        testing.allocator,
        "Paragraph with note[^one].\n\n[^one]: Footnote text",
        .{},
    );
    defer rendered.deinit(testing.allocator);

    try testing.expect(std.mem.indexOf(u8, rendered.html, "footnote-ref") != null);
    try testing.expect(std.mem.indexOf(u8, rendered.html, "Footnote text") != null);
}

test "renderAlloc renders citations and bibliography" {
    const rendered = try renderAlloc(
        testing.allocator,
        "A claim from prior work [@smith2024; @jones2023].\n\n[@smith2024]: Smith. Example Paper. 2024.\n[@jones2023]: Jones. Another Paper. 2023.",
        .{},
    );
    defer rendered.deinit(testing.allocator);

    try testing.expect(std.mem.indexOf(u8, rendered.html, "citation-group") != null);
    try testing.expect(std.mem.indexOf(u8, rendered.html, "References") != null);
    try testing.expect(std.mem.indexOf(u8, rendered.html, "Smith. Example Paper. 2024.") != null);
    try testing.expect(std.mem.indexOf(u8, rendered.html, "Jones. Another Paper. 2023.") != null);
}

test "renderAlloc renders citations from imported bibliography entries" {
    var entries = BibliographyEntries.init(testing.allocator);
    defer entries.deinit();

    try entries.put("nickerson2024", "Nickerson, Ada; Patel, Rohan. Thresholds As Interfaces For Interpretable Evaluation. Journal of Example Systems. 2024.");

    const rendered = try renderAlloc(
        testing.allocator,
        "Imported citations also work [@nickerson2024].",
        .{ .bibliography_entries = &entries },
    );
    defer rendered.deinit(testing.allocator);

    try testing.expect(std.mem.indexOf(u8, rendered.html, "citation-group") != null);
    try testing.expect(std.mem.indexOf(u8, rendered.html, "Thresholds As Interfaces For Interpretable Evaluation") != null);
}

test "renderAlloc rewrites asset image paths through the manifest" {
    var manifest = assets.Manifest.init(testing.allocator);
    defer manifest.deinit();

    try manifest.map.put(
        manifest.arena.allocator(),
        try manifest.arena.allocator().dupe(u8, "research-curve.svg"),
        try manifest.arena.allocator().dupe(u8, "assets/research-curve-hash.svg"),
    );

    const rendered = try renderAlloc(
        testing.allocator,
        "![A toy calibration curve](/assets/research-curve.svg)",
        .{ .asset_manifest = &manifest },
    );
    defer rendered.deinit(testing.allocator);

    try testing.expect(std.mem.indexOf(u8, rendered.html, "src=\"/assets/research-curve-hash.svg\"") != null);
}

test "renderAlloc renders admonition directives" {
    const rendered = try renderAlloc(
        testing.allocator,
        ":::note Reading hint\nThis body keeps **markdown** formatting.\n:::",
        .{},
    );
    defer rendered.deinit(testing.allocator);

    try testing.expect(std.mem.indexOf(u8, rendered.html, "admonition-note") != null);
    try testing.expect(std.mem.indexOf(u8, rendered.html, "Reading hint") != null);
    try testing.expect(std.mem.indexOf(u8, rendered.html, "<strong>markdown</strong>") != null);
}

test "renderAlloc renders details directives and sidenotes" {
    const rendered = try renderAlloc(
        testing.allocator,
        "Paragraph with a sidenote ^[Margin detail].\n\n:::details Expand this\nHidden body\n:::",
        .{},
    );
    defer rendered.deinit(testing.allocator);

    try testing.expect(std.mem.indexOf(u8, rendered.html, "class=\"sidenote\"") != null);
    try testing.expect(std.mem.indexOf(u8, rendered.html, "Margin detail") != null);
    try testing.expect(std.mem.indexOf(u8, rendered.html, "<details class=\"details-block\">") != null);
    try testing.expect(std.mem.indexOf(u8, rendered.html, "Expand this") != null);
}

test "preprocessInteractiveFigures rewrites interactive directives" {
    const preprocessed = try preprocessInteractiveFigures(
        testing.allocator,
        ":::interactive research-plot.js Threshold sweep\nInteractive caption text.\n:::\n",
    );
    defer preprocessed.deinit(testing.allocator);

    try testing.expect(preprocessed.requires_mustache);
    try testing.expect(std.mem.indexOf(u8, preprocessed.content, "{{& component research-plot.js}}") != null);
    try testing.expect(std.mem.indexOf(u8, preprocessed.content, "Interactive caption text.") != null);
}
