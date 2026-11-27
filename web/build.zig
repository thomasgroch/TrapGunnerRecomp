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

    // Desktop app for RecompLauncher (SDL2). `-Dsdl-include` / `-Dsdl-lib`
    // point at an SDL2 SDK (CI, Windows cross-builds); otherwise common system paths.
    const sdl_inc = b.option([]const u8, "sdl-include", "SDL2 include dir (contains SDL.h)");
    const sdl_lib = b.option([]const u8, "sdl-lib", "SDL2 library dir");
    const sdl_h = b.addWriteFiles().add("sdl.h", "#define SDL_MAIN_HANDLED\n#include <SDL.h>\n");
    const tc = b.addTranslateC(.{ .root_source_file = sdl_h, .target = target, .optimize = optimize });
    if (sdl_inc) |p| tc.addIncludePath(.{ .cwd_relative = p }) else {
        tc.addSystemIncludePath(.{ .cwd_relative = "/opt/homebrew/include/SDL2" });
        tc.addSystemIncludePath(.{ .cwd_relative = "/usr/include/SDL2" });
    }
    const desktop_mod = b.createModule(.{
        .root_source_file = b.path("src/desktop.zig"),
        .target = target,
        .optimize = optimize,
        .link_libc = true,
    });
    desktop_mod.addImport("sdl", tc.createModule());
    desktop_mod.addAnonymousImport("openbios", .{ .root_source_file = b.path("www/openbios.bin") });
    if (sdl_lib) |p| desktop_mod.addLibraryPath(.{ .cwd_relative = p }) else if (target.result.os.tag == .macos) {
        desktop_mod.addLibraryPath(.{ .cwd_relative = "/opt/homebrew/lib" });
    }
    if (target.result.os.tag == .windows and sdl_lib != null) {
        // the mingw SDK also ships a static libSDL2.a; link the DLL import library
        desktop_mod.addObjectFile(.{ .cwd_relative = b.pathJoin(&.{ sdl_lib.?, "libSDL2.dll.a" }) });
    } else desktop_mod.linkSystemLibrary("SDL2", .{});
    const desktop = b.addExecutable(.{ .name = "TrapGunner_Recompiled", .root_module = desktop_mod });
    if (target.result.os.tag == .windows) desktop.subsystem = .windows;
    if (target.result.os.tag == .linux) desktop_mod.addRPathSpecial("$ORIGIN");
    b.step("desktop", "Build the SDL2 desktop app (RecompLauncher)").dependOn(&b.addInstallArtifact(desktop, .{}).step);

    const tests = b.addTest(.{ .root_module = native_mod });
    b.step("test", "Unit tests").dependOn(&b.addRunArtifact(tests).step);
}
