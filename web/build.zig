const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    // Harness nativo: roda o núcleo (interpretador) direto no disco, para testes.
    const native_mod = b.createModule(.{
        .root_source_file = b.path("src/native.zig"),
        .target = target,
        .optimize = optimize,
    });
    const native = b.addExecutable(.{ .name = "psxweb-native", .root_module = native_mod });
    b.installArtifact(native);

    // Núcleo para o navegador (wasm32-freestanding), sem libc.
    const wasm_mod = b.createModule(.{
        .root_source_file = b.path("src/wasm.zig"),
        .target = b.resolveTargetQuery(.{ .cpu_arch = .wasm32, .os_tag = .freestanding }),
        .optimize = .ReleaseFast,
    });
    const wasm = b.addExecutable(.{ .name = "psxcore", .root_module = wasm_mod });
    wasm.entry = .disabled;
    wasm.rdynamic = true;
    wasm.import_memory = false;
    wasm.initial_memory = 32 * 1024 * 1024;
    wasm.max_memory = 64 * 1024 * 1024;
    const install_wasm = b.addInstallFile(wasm.getEmittedBin(), "../www/psxcore.wasm");
    b.step("wasm", "Build www/psxcore.wasm").dependOn(&install_wasm.step);

    const tests = b.addTest(.{ .root_module = native_mod });
    b.step("test", "Unit tests").dependOn(&b.addRunArtifact(tests).step);
}
