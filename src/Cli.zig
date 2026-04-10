//! The Goku CLI
//!
//! Commands:
//! - init
//! - build
//! - preview

pub fn printHelp() void {
    std.debug.print("{s}", .{standard_help});
}

pub const Command = union(enum) {
    build: Build,
    help: void,
    init: Init,
    preview: Preview,

    pub const Build = struct {
        site_root: union(enum) {
            absolute: []const u8,
            relative: []const u8,
        },
        out_dir: []const u8 = "build",
        url_prefix: ?[]const u8 = null,
        theme: ?[]const u8 = null,
    };
    pub const Init = struct {
        site_root: union(enum) {
            absolute: []const u8,
            relative: []const u8,
        },
    };
    pub const Preview = struct {
        site_root: union(enum) {
            absolute: []const u8,
            relative: []const u8,
        },
        out_dir: []const u8 = "build",
        url_prefix: ?[]const u8 = null,
        theme: ?[]const u8 = null,
    };

    /// Assumes the exe name has already been consumed in the iterator
    pub fn parse(args: *process.Args.Iterator) !?Command {
        const command = args.next() orelse return null;

        if (mem.eql(u8, command, "build")) {
            return try parseBuildArgs(args);
        } else if (mem.eql(u8, command, "help")) {
            return .help;
        } else if (mem.eql(u8, command, "init")) {
            return try parseInitArgs(args);
        } else if (mem.eql(u8, command, "preview")) {
            return try parsePreviewArgs(args);
        }

        return null;
    }

    pub fn parseBuildArgs(args: *process.Args.Iterator) !Command {
        var site_root: ?[]const u8 = null;
        var out_dir: ?[]const u8 = null;
        var url_prefix: ?[]const u8 = null;
        var theme: ?[]const u8 = null;

        while (args.next()) |arg| {
            if (mem.eql(u8, arg, "-o")) {
                if (out_dir != null) return error.TooManyArguments;
                out_dir = args.next() orelse return error.MissingOutDir;
            } else if (mem.eql(u8, arg, "-p")) {
                if (url_prefix != null) return error.TooManyArguments;
                url_prefix = args.next() orelse return error.MissingUrlPrefix;
            } else if (mem.eql(u8, arg, "-t")) {
                if (theme != null) return error.TooManyArguments;
                theme = args.next() orelse return error.MissingTheme;
            } else {
                if (site_root != null) return error.TooManyArguments;
                site_root = arg;
            }
        }

        if (site_root == null) return error.MissingSiteRoot;
        var build: Build = .{
            .site_root = if (fs.path.isAbsolute(site_root.?))
                .{ .absolute = site_root.? }
            else
                .{ .relative = site_root.? },
        };
        if (out_dir) |path| build.out_dir = path;
        if (url_prefix) |prefix| build.url_prefix = prefix;
        if (theme) |value| build.theme = value;
        return .{ .build = build };
    }

    pub fn parsePreviewArgs(args: *process.Args.Iterator) !Command {
        var site_root: ?[]const u8 = null;
        var out_dir: ?[]const u8 = null;
        var url_prefix: ?[]const u8 = null;
        var theme: ?[]const u8 = null;

        while (args.next()) |arg| {
            if (mem.eql(u8, arg, "-o")) {
                if (out_dir != null) return error.TooManyArguments;
                out_dir = args.next() orelse return error.MissingOutDir;
            } else if (mem.eql(u8, arg, "-p")) {
                if (url_prefix != null) return error.TooManyArguments;
                url_prefix = args.next() orelse return error.MissingUrlPrefix;
            } else if (mem.eql(u8, arg, "-t")) {
                if (theme != null) return error.TooManyArguments;
                theme = args.next() orelse return error.MissingTheme;
            } else {
                if (site_root != null) return error.TooManyArguments;
                site_root = arg;
            }
        }

        if (site_root == null) return error.MissingSiteRoot;

        var preview: Preview = .{ .site_root = if (fs.path.isAbsolute(site_root.?))
            .{ .absolute = site_root.? }
        else
            .{ .relative = site_root.? } };
        if (out_dir) |path| preview.out_dir = path;
        if (url_prefix) |prefix| preview.url_prefix = prefix;
        if (theme) |value| preview.theme = value;
        return .{ .preview = preview };
    }

    pub fn parseInitArgs(args: *process.Args.Iterator) !Command {
        var site_root: ?[]const u8 = null;

        while (args.next()) |arg| {
            if (site_root == null) {
                site_root = arg;
            } else {
                return error.TooManyArguments;
            }
        }

        if (site_root == null) {
            site_root = ".";
        }

        return .{
            .init = .{
                .site_root = if (fs.path.isAbsolute(site_root.?))
                    .{ .absolute = site_root.? }
                else
                    .{ .relative = site_root.? },
            },
        };
    }
};

const size_of_alice_txt = 1189000;

const standard_help =
    \\Goku - A static site generator
    \\----
    \\Usage:
    \\    goku -h
    \\    goku init [<site_root>]
    \\    goku build <site_root> -o <out_dir> [-p <url_prefix>]
    \\    goku preview <site_root> -o <out_dir> [-p <url_prefix>] [-t <theme>]
    \\    goku build <site_root> -o <out_dir> [-p <url_prefix>] [-t <theme>]
    \\
;

const debug = std.debug;
const fmt = std.fmt;
const fs = std.fs;
const heap = std.heap;
const log = std.log.scoped(.goku);
const mem = std.mem;
const httpz = @import("httpz");
const page = @import("page.zig");
const process = std.process;
const filesystem = @import("source/filesystem.zig");
const scaffold = @import("scaffold.zig");
const std = @import("std");
const storage = @import("storage.zig");
const testing = std.testing;
const time = std.time;
const Database = @import("Database.zig");
const Site = @import("Site.zig");
