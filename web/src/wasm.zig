//! API do núcleo para o navegador (wasm32-freestanding).
//! O host (worker.js) fornece `js_read_sector` (leitura síncrona do disco do
//! jogador) e chama `tg_frame` uma vez por quadro.
const std = @import("std");
const psxmod = @import("psx.zig");
const iso = @import("iso.zig");
const Psx = psxmod.Psx;

extern "env" fn js_read_sector(lba: u32, out: [*]u8) bool;
extern "env" fn js_log(ptr: [*]const u8, len: usize) void;

var g_psx: Psx = undefined;
export var bios_buf: [512 * 1024]u8 = undefined;
var exe_buf: [4 * 1024 * 1024]u8 = undefined;
export var fb: [640 * 480 * 4]u8 = undefined;
export var audio_buf: [8192]i16 = undefined;

fn readSector(lba: u32, out: *[2352]u8) bool {
    return js_read_sector(lba, out);
}

fn log(comptime fmt: []const u8, args: anytype) void {
    var buf: [256]u8 = undefined;
    const s = std.fmt.bufPrint(&buf, fmt, args) catch return;
    js_log(s.ptr, s.len);
}

export fn tg_bios_ptr() [*]u8 {
    return &bios_buf;
}
export fn tg_fb_ptr() [*]u8 {
    return &fb;
}

/// 0 = ok; 1 = EXE não achado; 2 = BIOS não chegou ao shell; 3 = EXE inválido
export fn tg_init(bios_len: u32, skip_fmv: bool) u32 {
    const e = iso.findRoot(readSector, "SLUS_006.79") orelse return 1;
    if (!iso.readFile(readSector, e, exe_buf[0..])) return 1;
    g_psx.init(bios_buf[0..bios_len], readSector);
    if (!g_psx.bootToShell()) return 2;
    if (!g_psx.loadExe(exe_buf[0..e.size])) return 3;
    if (skip_fmv) log("skip FMV: {}", .{g_psx.trapGunnerSkipFmv()});
    return 0;
}

/// Roda um quadro com os botões (ativo baixo) das duas portas.
/// Retorna largura | (altura << 16) da imagem em `fb`.
export fn tg_frame(pad1: u32, pad2: u32, pad2_connected: bool) u32 {
    g_psx.sio.buttons[0] = @truncate(pad1);
    g_psx.sio.buttons[1] = @truncate(pad2);
    g_psx.sio.connected[1] = pad2_connected;
    g_psx.runFrame(psxmod.interpRun);
    const d = g_psx.gpu.renderDisplay(&fb);
    return d.w | (d.h << 16);
}

export fn tg_audio_ptr() [*]i16 {
    return &audio_buf;
}
/// Copies the samples generated since the last call (interleaved stereo)
/// into `audio_buf`; returns how many i16 were copied.
export fn tg_audio() u32 {
    const s = &g_psx.spu;
    var n: u32 = 0;
    while (s.out_r != s.out_w and n < audio_buf.len) : (n += 1) {
        audio_buf[n] = s.out[s.out_r & 16383];
        s.out_r +%= 1;
    }
    return n;
}
