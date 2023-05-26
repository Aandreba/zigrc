const std = @import("std");

const Target = std.Target;
const CrossTarget = std.zig.CrossTarget;

const Arch = Target.Cpu.Arch;
const Os = Target.Os.Tag;

pub fn build(b: *std.build.Builder) void {
    // Standard release options allow the person running `zig build` to select
    // between Debug, ReleaseSafe, ReleaseFast, and ReleaseSmall.
    const mode = b.standardReleaseOptions();

    const linux_64 = build_target(b, mode, Arch.x86_64, Os.linux);
    linux_64.install();

    const main_tests = b.addTest("src/tests.zig");
    main_tests.setBuildMode(mode);

    const test_step = b.step("test", "Run library tests");
    test_step.dependOn(&main_tests.step);
}

fn build_target(b: *std.build.Builder, mode: std.builtin.Mode, arch: Target.Cpu.Arch, os_tag: Target.Os.Tag) *std.build.LibExeObjStep {
    const lib = b.addStaticLibrary("zig-rc", "src/main.zig");
    lib.emit_docs = .emit;
    lib.setBuildMode(mode);
    lib.setTarget(CrossTarget.fromTarget(default_target(arch, os_tag)));
    return lib;
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
