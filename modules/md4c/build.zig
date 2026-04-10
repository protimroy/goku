const debug = std.debug;
const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    const upstream = b.dependency("upstream", .{
        .target = target,
        .optimize = optimize,
    });

    const lib = b.addLibrary(.{
        .name = "md4c",
        .linkage = .static,
        .root_module = b.createModule(.{
            .target = target,
            .optimize = optimize,
            .link_libc = true,
        }),
    });

        lib.root_module.addCSourceFiles(.{
        .root = upstream.path("src"),
        .files = source_files,
        .flags = compile_flags,
    });

    lib.installHeadersDirectory(
        upstream.path("src"),
        "",
        .{},
    );

    const install = b.addInstallArtifact(lib, .{});

    b.getInstallStep().dependOn(&install.step);
}

const source_files = &.{
    "entity.c",
    "md4c.c",
    "md4c-html.c",
};

const compile_flags = &.{
    "-Wall",
    "-Wextra",
    "-Wshadow",
};
