const c = @import("c");
const debug = std.debug;
const fmt = std.fmt;
const io = std.Io;
const log = std.log.scoped(.@"page.Data");
const math = std.math;
const mem = std.mem;
const CodeFence = @import("CodeFence.zig");
const std = @import("std");
const testing = std.testing;

slug: []const u8,
collection: ?[]const u8 = null,
title: ?[]const u8 = null,
date: ?[]const u8 = null,
template: ?[]const u8 = null,
description: ?[]const u8 = null,
author: ?[]const u8 = null,
updated: ?[]const u8 = null,
image: ?[]const u8 = null,
canonical_url: ?[]const u8 = null,
doi: ?[]const u8 = null,
bibliography: ?[]const u8 = null,
theme: ?[]const u8 = null,
paginate: ?u32 = null,
allow_html: bool = false,
options_toc: bool = false,

const Data = @This();

pub fn fromReader(allocator: mem.Allocator, reader: anytype, max_len: usize) error{
    MissingSlug,
    MissingTitle,
    ParseError,
    ReadError,
    MissingFrontmatter,
    MissingTemplate,
}!Data {
    const bytes: []const u8 = readAllAllocCompat(reader, allocator, max_len) catch return error.ReadError;
    defer allocator.free(bytes);

    const code_fence_result = CodeFence.parse(bytes) orelse return error.MissingFrontmatter;

    return fromYamlString(
        allocator,
        code_fence_result.within,
        null,
    ) catch |err| return switch (err) {
        error.MissingSlug,
        error.MissingTitle,
        error.MissingTemplate,
        => |e| e,
        else => error.ParseError,
    };
}

fn readAllAllocCompat(source_reader: anytype, allocator: mem.Allocator, max_len: usize) ![]const u8 {
    const ReaderType = switch (@typeInfo(@TypeOf(source_reader))) {
        .pointer => |pointer| pointer.child,
        else => @TypeOf(source_reader),
    };

    var reader = source_reader;
    if (@hasDecl(ReaderType, "readAllAlloc")) {
        return reader.readAllAlloc(allocator, max_len);
    }
    return reader.allocRemaining(allocator, .limited(max_len));
}

pub const Diagnostics = struct {
    reason: []const u8,
    line: usize,
    col: usize,

    pub fn printErr(self: Diagnostics, logger: anytype) void {
        logger.err("Encountered a yaml parsing error: {s}\nLine: {d} Column: {d}\n", .{
            self.reason,
            self.line,
            self.col,
        });
    }
};

// Duplicates slices from the input data. Caller is responsible for
// calling page_data.deinit(allocator) afterwards.
pub fn fromYamlString(allocator: mem.Allocator, data: []const u8, diag: ?*Diagnostics) !Data {
    var parser: c.yaml_parser_t = undefined;
    const ptr: [*c]c.yaml_parser_t = &parser;

    if (c.yaml_parser_initialize(ptr) == 0) {
        return error.YamlParserInit;
    }
    defer c.yaml_parser_delete(ptr);

    c.yaml_parser_set_input_string(ptr, @ptrCast(data), data.len);

    var done: bool = false;

    var ev: c.yaml_event_t = undefined;
    const ev_ptr: [*c]c.yaml_event_t = &ev;
    var next_scalar_expected: enum {
        key,
        slug,
        title,
        discard,
        date,
        collection,
        description,
        author,
        updated,
        image,
        canonical_url,
        doi,
        bibliography,
        template,
        allow_html,
        options_toc,
        theme,
        paginate,
        tags,
    } = .key;
    var slug: ?[]const u8 = null;
    errdefer if (slug) |f| allocator.free(f);

    var title: ?[]const u8 = null;
    errdefer if (title) |f| allocator.free(f);

    var template: ?[]const u8 = null;
    errdefer if (template) |f| allocator.free(f);

    var collection: ?[]const u8 = null;
    errdefer if (collection) |f| allocator.free(f);

    var description: ?[]const u8 = null;
    errdefer if (description) |f| allocator.free(f);

    var author: ?[]const u8 = null;
    errdefer if (author) |f| allocator.free(f);

    var updated: ?[]const u8 = null;
    errdefer if (updated) |f| allocator.free(f);

    var image: ?[]const u8 = null;
    errdefer if (image) |f| allocator.free(f);

    var canonical_url: ?[]const u8 = null;
    errdefer if (canonical_url) |f| allocator.free(f);

    var doi: ?[]const u8 = null;
    errdefer if (doi) |f| allocator.free(f);

    var bibliography: ?[]const u8 = null;
    errdefer if (bibliography) |f| allocator.free(f);

    var date: ?[]const u8 = null;
    errdefer if (date) |f| allocator.free(f);

    var theme: ?[]const u8 = null;
    errdefer if (theme) |f| allocator.free(f);

    var paginate: ?u32 = null;

    var allow_html: bool = false;
    var options_toc: bool = false;

    while (!done) {
        if (c.yaml_parser_parse(ptr, ev_ptr) == 0) {
            if (diag) |d| {
                // Populate diagnostics info for later reporting
                d.* = .{
                    .reason = mem.sliceTo(parser.problem, 0),
                    .line = parser.problem_mark.line + 1,
                    .col = parser.problem_mark.column + 1,
                };
            }
            return error.Parse;
        }

        switch (ev.type) {
            c.YAML_STREAM_START_EVENT => {},
            c.YAML_STREAM_END_EVENT => {},
            c.YAML_DOCUMENT_START_EVENT => {},
            c.YAML_DOCUMENT_END_EVENT => {},
            c.YAML_SCALAR_EVENT => {
                const scalar = ev.data.scalar;
                const value = scalar.value[0..scalar.length];

                switch (next_scalar_expected) {
                    .key => {
                        if (mem.eql(u8, value, "slug")) {
                            next_scalar_expected = .slug;
                        } else if (mem.eql(u8, value, "title")) {
                            next_scalar_expected = .title;
                        } else if (mem.eql(u8, value, "collection")) {
                            next_scalar_expected = .collection;
                        } else if (mem.eql(u8, value, "date")) {
                            next_scalar_expected = .date;
                        } else if (mem.eql(u8, value, "tags")) {
                            next_scalar_expected = .tags;
                        } else if (mem.eql(u8, value, "description")) {
                            next_scalar_expected = .description;
                        } else if (mem.eql(u8, value, "author")) {
                            next_scalar_expected = .author;
                        } else if (mem.eql(u8, value, "updated")) {
                            next_scalar_expected = .updated;
                        } else if (mem.eql(u8, value, "image")) {
                            next_scalar_expected = .image;
                        } else if (mem.eql(u8, value, "canonical_url")) {
                            next_scalar_expected = .canonical_url;
                        } else if (mem.eql(u8, value, "doi")) {
                            next_scalar_expected = .doi;
                        } else if (mem.eql(u8, value, "bibliography")) {
                            next_scalar_expected = .bibliography;
                        } else if (mem.eql(u8, value, "template")) {
                            next_scalar_expected = .template;
                        } else if (mem.eql(u8, value, "allow_html")) {
                            next_scalar_expected = .allow_html;
                        } else if (mem.eql(u8, value, "options_toc")) {
                            next_scalar_expected = .options_toc;
                        } else if (mem.eql(u8, value, "theme")) {
                            next_scalar_expected = .theme;
                        } else if (mem.eql(u8, value, "paginate")) {
                            next_scalar_expected = .paginate;
                        } else {
                            next_scalar_expected = .discard;
                        }
                    },
                    .slug => {
                        slug = try allocator.dupe(u8, value);
                        next_scalar_expected = .key;
                    },
                    .template => {
                        template = try allocator.dupe(u8, value);
                        next_scalar_expected = .key;
                    },
                    .title => {
                        title = try allocator.dupe(u8, value);
                        next_scalar_expected = .key;
                    },
                    .allow_html => {
                        if (mem.eql(u8, value, "true")) {
                            allow_html = true;
                        } else if (mem.eql(u8, value, "false")) {
                            allow_html = false;
                        } else {
                            return error.UnexpectedValue;
                        }
                        next_scalar_expected = .key;
                    },
                    .options_toc => {
                        if (mem.eql(u8, value, "true")) {
                            options_toc = true;
                        } else if (mem.eql(u8, value, "false")) {
                            options_toc = false;
                        } else {
                            return error.UnexpectedValue;
                        }
                        next_scalar_expected = .key;
                    },
                    .collection => {
                        collection = try allocator.dupe(u8, value);
                        next_scalar_expected = .key;
                    },
                    .tags => {
                        next_scalar_expected = .key;
                    },
                    .date => {
                        date = try allocator.dupe(u8, value);
                        next_scalar_expected = .key;
                    },
                    .description => {
                        description = try allocator.dupe(u8, value);
                        next_scalar_expected = .key;
                    },
                    .author => {
                        author = try allocator.dupe(u8, value);
                        next_scalar_expected = .key;
                    },
                    .updated => {
                        updated = try allocator.dupe(u8, value);
                        next_scalar_expected = .key;
                    },
                    .image => {
                        image = try allocator.dupe(u8, value);
                        next_scalar_expected = .key;
                    },
                    .canonical_url => {
                        canonical_url = try allocator.dupe(u8, value);
                        next_scalar_expected = .key;
                    },
                    .doi => {
                        doi = try allocator.dupe(u8, value);
                        next_scalar_expected = .key;
                    },
                    .bibliography => {
                        bibliography = try allocator.dupe(u8, value);
                        next_scalar_expected = .key;
                    },
                    .theme => {
                        theme = try allocator.dupe(u8, value);
                        next_scalar_expected = .key;
                    },
                    .paginate => {
                        paginate = try fmt.parseInt(u32, value, 10);
                        next_scalar_expected = .key;
                    },
                    .discard => {
                        next_scalar_expected = .key;
                    },
                }
            },
            c.YAML_SEQUENCE_START_EVENT => {},
            c.YAML_SEQUENCE_END_EVENT => {},
            c.YAML_MAPPING_START_EVENT => {},
            c.YAML_MAPPING_END_EVENT => {},
            c.YAML_ALIAS_EVENT => {},
            c.YAML_NO_EVENT => {},
            else => {},
        }

        done = (ev.type == c.YAML_STREAM_END_EVENT);

        c.yaml_event_delete(ev_ptr);
    }

    if (slug == null or slug.?.len == 0) return error.MissingSlug;
    if (title == null or title.?.len == 0) return error.MissingTitle;
    if (template == null or template.?.len == 0) return error.MissingTemplate;

    return .{
        .slug = slug.?,
        .title = title,
        .template = template,
        .collection = collection,
        .allow_html = allow_html,
        .options_toc = options_toc,
        .date = date,
        .description = description,
        .author = author,
        .updated = updated,
        .image = image,
        .canonical_url = canonical_url,
        .doi = doi,
        .bibliography = bibliography,
        .theme = theme,
        .paginate = paginate,
    };
}

pub fn deinit(self: Data, allocator: mem.Allocator) void {
    allocator.free(self.slug);
    if (self.title) |title| {
        allocator.free(title);
    }
    if (self.template) |template| {
        allocator.free(template);
    }

    if (self.collection) |collection| {
        allocator.free(collection);
    }

    if (self.date) |date| {
        allocator.free(date);
    }

    if (self.description) |description| {
        allocator.free(description);
    }
    if (self.author) |author| {
        allocator.free(author);
    }
    if (self.updated) |updated| {
        allocator.free(updated);
    }
    if (self.image) |image| {
        allocator.free(image);
    }
    if (self.canonical_url) |canonical_url| {
        allocator.free(canonical_url);
    }
    if (self.doi) |doi| {
        allocator.free(doi);
    }
    if (self.bibliography) |bibliography| {
        allocator.free(bibliography);
    }
    if (self.theme) |theme| {
        allocator.free(theme);
    }
}

test fromReader {
    const input =
        \\---
        \\slug: /
        \\title: Home page
        \\template: foo.html
        \\---
    ;

    var reader = io.Reader.fixed(input);

    const yaml = try fromReader(
        testing.allocator,
        &reader,
        std.math.maxInt(usize),
    );

    defer yaml.deinit(testing.allocator);

    try testing.expectEqualStrings("/", yaml.slug);
    try testing.expectEqualStrings("Home page", yaml.title.?);
}

test "fromReader - fail(empty frontmatter)" {
    var reader = io.Reader.fixed(
        \\---
        \\---
        ,
    );

    const result = fromReader(
        testing.allocator,
        &reader,
        math.maxInt(usize),
    );

    try testing.expectError(
        error.MissingFrontmatter,
        result,
    );
}

test "fromReader - fail(invalid yaml)" {
    var reader = io.Reader.fixed(
        \\---
        \\:
        \\---
        ,
    );

    const result = fromReader(
        testing.allocator,
        &reader,
        math.maxInt(usize),
    );

    try testing.expectError(
        error.ParseError,
        result,
    );
}

test fromYamlString {
    const input =
        \\slug: /
        \\title: Home page
        \\template: foo.html
    ;

    const yaml = try fromYamlString(
        testing.allocator,
        input,
        null,
    );

    defer yaml.deinit(testing.allocator);

    try testing.expectEqualStrings("/", yaml.slug);
    try testing.expectEqualStrings("Home page", yaml.title.?);
}

test "fromYamlString parses options_toc" {
    const input =
        \\slug: /
        \\title: Home page
        \\template: foo.html
        \\options_toc: true
    ;

    const yaml = try fromYamlString(
        testing.allocator,
        input,
        null,
    );
    defer yaml.deinit(testing.allocator);

    try testing.expectEqual(true, yaml.options_toc);
}

test "fromYamlString parses seo metadata fields" {
    const input =
        \\slug: /paper
        \\title: Paper
        \\template: page.html
        \\author: Researcher
        \\updated: 2026-04-01
        \\image: /images/cover.png
        \\canonical_url: https://example.com/paper
        \\doi: 10.1000/example
        \\bibliography: bibliography/references.bib
    ;

    const yaml = try fromYamlString(testing.allocator, input, null);
    defer yaml.deinit(testing.allocator);

    try testing.expectEqualStrings("Researcher", yaml.author.?);
    try testing.expectEqualStrings("2026-04-01", yaml.updated.?);
    try testing.expectEqualStrings("/images/cover.png", yaml.image.?);
    try testing.expectEqualStrings("https://example.com/paper", yaml.canonical_url.?);
    try testing.expectEqualStrings("10.1000/example", yaml.doi.?);
    try testing.expectEqualStrings("bibliography/references.bib", yaml.bibliography.?);
}

test "fromYamlString - Error" {
    const invalid_input =
        \\: 
    ;

    const result = fromYamlString(
        testing.allocator,
        invalid_input,
        null,
    );

    try testing.expectError(error.Parse, result);
}

test "correct diagnostics" {
    const invalid_input =
        \\:
    ;

    var diag: Diagnostics = undefined;
    const result = fromYamlString(
        testing.allocator,
        invalid_input,
        &diag,
    );

    try testing.expectError(error.Parse, result);
    try testing.expectEqualStrings("did not find expected key", diag.reason);
}
