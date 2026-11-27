//! Desktop frontend (Linux/Windows/macOS) for the MIT Zig PS1 core, used by
//! RecompLauncher. It reads the player's own disc (.cue or .bin), boots the
//! bundled OpenBIOS (MIT) and draws/plays with SDL2. No game code is shipped.
//!
//!   TrapGunner_Recompiled --disc "Trap Gunner.cue" [--skip-fmv] [--fullscreen]
//!   (--game <file> is accepted and ignored, for RecompLauncher compatibility)
const std = @import("std");
const Io = std.Io;
const psxmod = @import("psx.zig");
const iso = @import("iso.zig");
const Psx = psxmod.Psx;
const c = @import("sdl");

const bios_bin = @embedFile("openbios");

var g_psx: Psx = undefined;
var g_io: Io = undefined;
var g_disc: Io.File = undefined;
var exe_buf: [4 * 1024 * 1024]u8 = undefined;
var fb: [640 * 480 * 4]u8 = undefined;

fn readSector(lba: u32, out: *[2352]u8) bool {
    const n = g_disc.readPositionalAll(g_io, out, @as(u64, lba) * 2352) catch return false;
    return n == 2352;
}

/// A .cue points at the .bin with `FILE "name" BINARY`; anything else is the image itself.
fn resolveDisc(io: Io, arena: std.mem.Allocator, path: []const u8) ![]const u8 {
    if (!std.ascii.endsWithIgnoreCase(path, ".cue")) return path;
    const cue = try Io.Dir.cwd().readFileAlloc(io, path, arena, .limited(64 * 1024));
    var lines = std.mem.tokenizeAny(u8, cue, "\r\n");
    while (lines.next()) |line| {
        const t = std.mem.trim(u8, line, " \t");
        if (!std.ascii.startsWithIgnoreCase(t, "FILE")) continue;
        const a = std.mem.indexOfScalar(u8, t, '"') orelse continue;
        const b = std.mem.lastIndexOfScalar(u8, t, '"') orelse continue;
        if (b <= a + 1) continue;
        const name = t[a + 1 .. b];
        const dir = std.fs.path.dirname(path) orelse ".";
        return std.fs.path.join(arena, &.{ dir, name });
    }
    return error.CueWithoutFile;
}

// PS1 buttons (active low in the core): bit numbers.
const Btn = enum(u4) { select = 0, start = 3, up = 4, right = 5, down = 6, left = 7, l2 = 8, r2 = 9, l1 = 10, r1 = 11, tri = 12, circle = 13, cross = 14, square = 15 };
fn bit(b: Btn) u16 {
    return @as(u16, 1) << @intFromEnum(b);
}

fn keyboardMask() u16 {
    const ks = c.SDL_GetKeyboardState(null);
    const map = [_]struct { c_int, Btn }{
        .{ c.SDL_SCANCODE_UP, .up },       .{ c.SDL_SCANCODE_DOWN, .down },    .{ c.SDL_SCANCODE_LEFT, .left },
        .{ c.SDL_SCANCODE_RIGHT, .right }, .{ c.SDL_SCANCODE_X, .cross },      .{ c.SDL_SCANCODE_Z, .circle },
        .{ c.SDL_SCANCODE_S, .square },    .{ c.SDL_SCANCODE_A, .tri },        .{ c.SDL_SCANCODE_RETURN, .start },
        .{ c.SDL_SCANCODE_LSHIFT, .select }, .{ c.SDL_SCANCODE_RSHIFT, .select }, .{ c.SDL_SCANCODE_Q, .l1 },
        .{ c.SDL_SCANCODE_W, .r1 },        .{ c.SDL_SCANCODE_E, .l2 },         .{ c.SDL_SCANCODE_R, .r2 },
    };
    var m: u16 = 0;
    for (map) |e| if (ks[@intCast(e[0])] != 0) {
        m |= bit(e[1]);
    };
    return m;
}

fn padMask(gc: ?*c.SDL_GameController) u16 {
    const p = gc orelse return 0;
    const map = [_]struct { c_int, Btn }{
        .{ c.SDL_CONTROLLER_BUTTON_A, .cross },         .{ c.SDL_CONTROLLER_BUTTON_B, .circle },
        .{ c.SDL_CONTROLLER_BUTTON_X, .square },        .{ c.SDL_CONTROLLER_BUTTON_Y, .tri },
        .{ c.SDL_CONTROLLER_BUTTON_LEFTSHOULDER, .l1 }, .{ c.SDL_CONTROLLER_BUTTON_RIGHTSHOULDER, .r1 },
        .{ c.SDL_CONTROLLER_BUTTON_BACK, .select },     .{ c.SDL_CONTROLLER_BUTTON_START, .start },
        .{ c.SDL_CONTROLLER_BUTTON_DPAD_UP, .up },      .{ c.SDL_CONTROLLER_BUTTON_DPAD_DOWN, .down },
        .{ c.SDL_CONTROLLER_BUTTON_DPAD_LEFT, .left },  .{ c.SDL_CONTROLLER_BUTTON_DPAD_RIGHT, .right },
    };
    var m: u16 = 0;
    for (map) |e| if (c.SDL_GameControllerGetButton(p, e[0]) != 0) {
        m |= bit(e[1]);
    };
    const ax = struct {
        fn get(g: *c.SDL_GameController, a: c_int) i32 {
            return c.SDL_GameControllerGetAxis(g, a);
        }
    };
    if (ax.get(p, c.SDL_CONTROLLER_AXIS_TRIGGERLEFT) > 16000) m |= bit(.l2);
    if (ax.get(p, c.SDL_CONTROLLER_AXIS_TRIGGERRIGHT) > 16000) m |= bit(.r2);
    const x = ax.get(p, c.SDL_CONTROLLER_AXIS_LEFTX);
    const y = ax.get(p, c.SDL_CONTROLLER_AXIS_LEFTY);
    if (x < -16000) m |= bit(.left);
    if (x > 16000) m |= bit(.right);
    if (y < -16000) m |= bit(.up);
    if (y > 16000) m |= bit(.down);
    return m;
}

fn fail(comptime fmt: []const u8, args: anytype) noreturn {
    var buf: [512]u8 = undefined;
    const msg = std.fmt.bufPrint(buf[0 .. buf.len - 1], fmt, args) catch "erro";
    buf[msg.len] = 0;
    std.debug.print("{s}\n", .{msg});
    _ = c.SDL_ShowSimpleMessageBox(c.SDL_MESSAGEBOX_ERROR, "Trap Gunner", @ptrCast(&buf), null);
    std.process.exit(1);
}

pub fn main(init: std.process.Init) !void {
    const io = init.io;
    g_io = io;
    const arena = init.arena.allocator();
    const args = try init.minimal.args.toSlice(arena);

    var disc_path: ?[]const u8 = null;
    var skip_fmv = false;
    var fullscreen = false;
    var i: usize = 1;
    while (i < args.len) : (i += 1) {
        const a = args[i];
        if (std.mem.eql(u8, a, "--disc") and i + 1 < args.len) {
            i += 1;
            disc_path = args[i];
        } else if (std.mem.eql(u8, a, "--game") and i + 1 < args.len) {
            i += 1; // RecompLauncher passes game.toml; not needed here
        } else if (std.mem.eql(u8, a, "--skip-fmv")) {
            skip_fmv = true;
        } else if (std.mem.eql(u8, a, "--fullscreen")) {
            fullscreen = true;
        } else if (disc_path == null and a.len > 0 and a[0] != '-') {
            disc_path = a;
        }
    }

    if (c.SDL_Init(c.SDL_INIT_VIDEO | c.SDL_INIT_AUDIO | c.SDL_INIT_GAMECONTROLLER) != 0)
        fail("SDL_Init: {s}", .{c.SDL_GetError()});
    defer c.SDL_Quit();

    const dp = disc_path orelse fail("Uso: TrapGunner_Recompiled --disc \"Trap Gunner.cue\"", .{});
    const bin = resolveDisc(io, arena, dp) catch |e| fail("Não consegui ler {s}: {s}", .{ dp, @errorName(e) });
    g_disc = Io.Dir.cwd().openFile(io, bin, .{}) catch |e| fail("Não consegui abrir {s}: {s}", .{ bin, @errorName(e) });

    const e = iso.findRoot(readSector, "SLUS_006.79") orelse fail("SLUS_006.79 não encontrado: confira o dump (Trap Gunner USA, Redump).", .{});
    if (!iso.readFile(readSector, e, exe_buf[0..])) fail("Falha ao ler SLUS_006.79 do disco.", .{});
    const psx = &g_psx;
    psx.init(bios_bin, readSector);
    if (!psx.bootToShell()) fail("A BIOS não iniciou.", .{});
    if (!psx.loadExe(exe_buf[0..e.size])) fail("EXE inválido.", .{});
    if (skip_fmv) _ = psx.trapGunnerSkipFmv();

    var flags: u32 = c.SDL_WINDOW_RESIZABLE | c.SDL_WINDOW_ALLOW_HIGHDPI;
    if (fullscreen) flags |= c.SDL_WINDOW_FULLSCREEN_DESKTOP;
    const win = c.SDL_CreateWindow("Trap Gunner", c.SDL_WINDOWPOS_CENTERED, c.SDL_WINDOWPOS_CENTERED, 960, 720, flags) orelse
        fail("SDL_CreateWindow: {s}", .{c.SDL_GetError()});
    defer c.SDL_DestroyWindow(win);
    const ren = c.SDL_CreateRenderer(win, -1, c.SDL_RENDERER_ACCELERATED) orelse
        c.SDL_CreateRenderer(win, -1, 0) orelse fail("SDL_CreateRenderer: {s}", .{c.SDL_GetError()});
    defer c.SDL_DestroyRenderer(ren);
    _ = c.SDL_SetHint(c.SDL_HINT_RENDER_SCALE_QUALITY, "1");
    _ = c.SDL_RenderSetLogicalSize(ren, 640, 480);
    var tex: ?*c.SDL_Texture = null;
    var tex_w: u32 = 0;
    var tex_h: u32 = 0;

    var want = std.mem.zeroes(c.SDL_AudioSpec);
    want.freq = 44100;
    want.format = c.AUDIO_S16SYS;
    want.channels = 2;
    want.samples = 1024;
    const adev = c.SDL_OpenAudioDevice(null, 0, &want, null, 0);
    if (adev != 0) c.SDL_PauseAudioDevice(adev, 0);

    var pads: [2]?*c.SDL_GameController = .{ null, null };
    var audio: [8192]i16 = undefined;
    var next = c.SDL_GetPerformanceCounter();
    const freq = c.SDL_GetPerformanceFrequency();

    var running = true;
    while (running) {
        var ev: c.SDL_Event = undefined;
        while (c.SDL_PollEvent(&ev) != 0) {
            switch (ev.type) {
                c.SDL_QUIT => running = false,
                c.SDL_KEYDOWN => {
                    if (ev.key.keysym.sym == c.SDLK_F11 or (ev.key.keysym.sym == c.SDLK_RETURN and ev.key.keysym.mod & c.KMOD_ALT != 0)) {
                        fullscreen = !fullscreen;
                        _ = c.SDL_SetWindowFullscreen(win, if (fullscreen) c.SDL_WINDOW_FULLSCREEN_DESKTOP else 0);
                    }
                    if (ev.key.keysym.sym == c.SDLK_ESCAPE and fullscreen) {
                        fullscreen = false;
                        _ = c.SDL_SetWindowFullscreen(win, 0);
                    }
                },
                c.SDL_CONTROLLERDEVICEADDED, c.SDL_CONTROLLERDEVICEREMOVED => {
                    for (&pads) |*p| if (p.*) |g| {
                        c.SDL_GameControllerClose(g);
                        p.* = null;
                    };
                    var slot: usize = 0;
                    var j: c_int = 0;
                    while (j < c.SDL_NumJoysticks() and slot < 2) : (j += 1) {
                        if (c.SDL_IsGameController(j) == c.SDL_FALSE) continue;
                        pads[slot] = c.SDL_GameControllerOpen(j);
                        slot += 1;
                    }
                },
                else => {},
            }
        }

        // Fixed 59.94 Hz emulation, independent of the monitor's refresh rate.
        const now = c.SDL_GetPerformanceCounter();
        const step: u64 = freq * 1000 / 59940;
        if (now < next) {
            const ms: u32 = @intCast((next - now) * 1000 / freq);
            if (ms > 1) c.SDL_Delay(ms - 1);
            continue;
        }
        if (now - next > step * 6) next = now; // fell far behind (window drag): resync
        next += step;

        const p1 = keyboardMask() | padMask(pads[0]);
        const p2 = padMask(pads[1]);
        psx.sio.buttons[0] = ~p1;
        psx.sio.buttons[1] = ~p2;
        psx.sio.connected[1] = pads[1] != null;
        psx.runFrame(psxmod.interpRun);

        var n: u32 = 0;
        const s = &psx.spu;
        while (s.out_r != s.out_w and n < audio.len) : (n += 1) {
            audio[n] = s.out[s.out_r & 16383];
            s.out_r +%= 1;
        }
        if (adev != 0 and n > 0) {
            // keep at most ~100 ms queued so latency doesn't build up
            if (c.SDL_GetQueuedAudioSize(adev) > 44100 * 4 / 10) c.SDL_ClearQueuedAudio(adev);
            _ = c.SDL_QueueAudio(adev, &audio, n * 2);
        }

        if (c.SDL_GetPerformanceCounter() < next) { // draw only when not catching up
            const d = psx.gpu.renderDisplay(&fb);
            if (d.w == 0 or d.h == 0) continue;
            if (tex == null or d.w != tex_w or d.h != tex_h) {
                if (tex) |t| c.SDL_DestroyTexture(t);
                tex = c.SDL_CreateTexture(ren, c.SDL_PIXELFORMAT_ABGR8888, c.SDL_TEXTUREACCESS_STREAMING, @intCast(d.w), @intCast(d.h));
                tex_w = d.w;
                tex_h = d.h;
            }
            _ = c.SDL_UpdateTexture(tex, null, &fb, @intCast(d.w * 4));
            _ = c.SDL_SetRenderDrawColor(ren, 0, 0, 0, 255);
            _ = c.SDL_RenderClear(ren);
            _ = c.SDL_RenderCopy(ren, tex, null, null);
            c.SDL_RenderPresent(ren);
        }
    }
}
