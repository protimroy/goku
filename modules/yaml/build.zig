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
        .name = "yaml",
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

    lib.root_module.addConfigHeader(b.addConfigHeader(.{}, .{
        .YAML_VERSION_STRING = "0.2.5",
        .YAML_VERSION_MAJOR = 0,
        .YAML_VERSION_MINOR = 2,
        .YAML_VERSION_PATCH = 5,
    }));

    // To access yaml_private.h
    lib.root_module.addIncludePath(upstream.path("src"));
    // To access yaml.h
    lib.root_module.addIncludePath(upstream.path("include"));

    lib.installHeadersDirectory(
        upstream.path("include"),
        "",
        .{},
    );

    const install = b.addInstallArtifact(lib, .{});

    b.getInstallStep().dependOn(&install.step);
}

const source_files = &.{
    "parser.c",
    "scanner.c",
    "reader.c",
    "api.c",
};

const compile_flags = &.{
    "-std=gnu99",
    "-DHAVE_CONFIG_H",
};
