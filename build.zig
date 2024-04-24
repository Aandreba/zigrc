const std = @import("std");
const builtin = @import("builtin");

const Builder = if (builtin.zig_version.minor <= 10) std.build.Builder else std.Build;
const Mode = if (builtin.zig_version.minor <= 10) std.builtin.Mode else std.builtin.OptimizeMode;

const Target = std.Target;
const CrossTarget = std.zig.CrossTarget;

const Arch = Target.Cpu.Arch;
const Os = Target.Os.Tag;

pub fn build(b: *Builder) void {
    if (comptime builtin.zig_version.minor <= 10) {
        build_v10(b);
    } else if (comptime builtin.zig_version.minor <= 11) {
        build_v11(b);
    } else {
        build_v12(b);
    }
}

fn build_v10(b: *std.build.Builder) void {
    // Standard release options allow the person running `zig build` to select
    // between Debug, ReleaseSafe, ReleaseFast, and ReleaseSmall.
    const mode = b.standardReleaseOptions();
    const coverage = b.option(bool, "coverage", "Generate test coverage") orelse false;

    // Docs
    const docs = b.addStaticLibrary("zig-rc", "src/main.zig");
    docs.emit_docs = .emit;
    docs.setBuildMode(mode);
    docs.install();

    // Tests
    const main_tests = b.addTest("src/tests.zig");
    main_tests.setBuildMode(mode);

    if (coverage) {
        main_tests.setExecCmd(&[_]?[]const u8{
            "kcov",
            "--include-pattern=src/main.zig,src/tests.zig",
            "kcov-out",
            null, // to get zig to use the --test-cmd-bin flag
        });
    }

    const test_step = b.step("test", "Run library tests");
    test_step.dependOn(&main_tests.step);

    // Examples
    const example = b.addTest("src/example.zig");
    example.setBuildMode(mode);
    const example_step = b.step("example", "Run library example");
    example_step.dependOn(&example.step);
}

fn build_v11(b: *std.Build) void {
    // Standard target options allows the person running `zig build` to choose
    // what target to build for. Here we do not override the defaults, which
    // means any target is allowed, and the default is native. Other options
    // for restricting supported target set are available.
    const target = b.standardTargetOptions(.{});

    // Standard optimization options allow the person running `zig build` to select
    // between Debug, ReleaseSafe, ReleaseFast, and ReleaseSmall. Here we do not
    // set a preferred release mode, allowing the user to decide how to optimize.
    const optimize = b.standardOptimizeOption(.{});

    const coverage = b.option(bool, "coverage", "Generate test coverage") orelse false;

    // Docs
    const docs = b.addStaticLibrary(.{
        .name = "zig-rc",
        .root_source_file = std.build.LazyPath.relative("src/main.zig"),
        .target = target,
        .optimize = optimize,
    });

    const docsget = b.addInstallDirectory(.{
        .source_dir = docs.getEmittedDocs(),
        .install_dir = .prefix,
        .install_subdir = "docs",
    });

    b.default_step.dependOn(&docsget.step);

    b.installArtifact(docs);

    // Tests
    const main_tests = b.addTest(.{
        .root_source_file = std.build.LazyPath.relative("src/tests.zig"),
    });
    const run_main_tests = b.addRunArtifact(main_tests);

    if (coverage) {
        main_tests.setExecCmd(&[_]?[]const u8{
            "kcov",
            "--include-pattern=src/main.zig,src/tests.zig",
            "kcov-out",
            null, // to get zig to use the --test-cmd-bin flag
        });
    }

    const test_step = b.step("test", "Run library tests");
    test_step.dependOn(&run_main_tests.step);

    // Examples
    const example = b.addTest(.{
        .root_source_file = std.build.LazyPath.relative("src/example.zig"),
    });
    const run_example = b.addRunArtifact(example);
    const example_step = b.step("example", "Run library example");
    example_step.dependOn(&run_example.step);
}

fn build_v12(b: *std.Build) void {
    // Standard target options allows the person running `zig build` to choose
    // what target to build for. Here we do not override the defaults, which
    // means any target is allowed, and the default is native. Other options
    // for restricting supported target set are available.
    const target = b.standardTargetOptions(.{});

    // Standard optimization options allow the person running `zig build` to select
    // between Debug, ReleaseSafe, ReleaseFast, and ReleaseSmall. Here we do not
    // set a preferred release mode, allowing the user to decide how to optimize.
    const optimize = b.standardOptimizeOption(.{});

    const coverage = b.option(bool, "coverage", "Generate test coverage") orelse false;

    // Docs
    const docs = b.addStaticLibrary(.{
        .name = "zig-rc",
        .root_source_file = b.path("src/main.zig"),
        .target = target,
        .optimize = optimize,
    });

    const docsget = b.addInstallDirectory(.{
        .source_dir = docs.getEmittedDocs(),
        .install_dir = .prefix,
        .install_subdir = "docs",
    });

    b.default_step.dependOn(&docsget.step);

    b.installArtifact(docs);

    // Tests
    const main_tests = b.addTest(.{
        .root_source_file = b.path("src/tests.zig"),
    });
    const run_main_tests = b.addRunArtifact(main_tests);

    if (coverage) {
        main_tests.setExecCmd(&[_]?[]const u8{
            "kcov",
            "--include-pattern=src/main.zig,src/tests.zig",
            "kcov-out",
            null, // to get zig to use the --test-cmd-bin flag
        });
    }

    const test_step = b.step("test", "Run library tests");
    test_step.dependOn(&run_main_tests.step);

    // Examples
    const example = b.addTest(.{
        .root_source_file = b.path("src/example.zig"),
    });
    const run_example = b.addRunArtifact(example);
    const example_step = b.step("example", "Run library example");
    example_step.dependOn(&run_example.step);
}

fn default_target(arch: Target.Cpu.Arch, os_tag: Target.Os.Tag) Target {
    const os = os_tag.defaultVersionRange(arch);
    return Target{
        .cpu = Target.Cpu.baseline(arch),
        .abi = Target.Abi.default(arch, os),
        .os = os,
        .ofmt = Target.ObjectFormat.default(os_tag, arch),
    };
}
