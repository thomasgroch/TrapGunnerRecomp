//! Harness nativo do núcleo web: roda o interpretador direto no disco do
//! jogador e grava a VRAM em PPM. Serve para testar sem navegador.
//!   psxweb-native <bios.bin> <disco.bin> <exe> <frames> <saida.ppm> [press_frame:mask ...]
const std = @import("std");
const Io = std.Io;
const psxmod = @import("psx.zig");
const Psx = psxmod.Psx;

var g_io: Io = undefined;
var g_disc: Io.File = undefined;

fn readSector(lba: u32, out: *[2352]u8) bool {
    const n = g_disc.readPositionalAll(g_io, out, @as(u64, lba) * 2352) catch return false;
    return n == 2352;
}

var g_psx: Psx = undefined;
var g_clone: Psx = undefined;
var g_clone_done = false;

fn countBlocks(ram: []const u8, addr: u32, words: u32) u32 {
    var pos: u32 = 0;
    var blocks: u32 = 0;
    const n = words * 2;
    const H = struct {
        fn at(r: []const u8, a: u32, i: u32) u16 {
            return std.mem.readInt(u16, r[(a + i * 2) & 0x1FFFFF ..][0..2], .little);
        }
    };
    while (pos < n) {
        while (pos < n and H.at(ram, addr, pos) == 0xFE00) pos += 1;
        if (pos >= n) break;
        pos += 1;
        var k: u32 = 0;
        while (pos < n) {
            const h = H.at(ram, addr, pos);
            pos += 1;
            k += (h >> 10) + 1;
            if (k > 63) break;
        }
        blocks += 1;
    }
    return blocks;
}

/// Roda o decodificador VLC isolado (IRQs mascaradas) a partir do clone.
fn vlcExperiment() void {
    const c = &g_clone;
    const out = c.cpu.r[5] & 0x1FFFFF; // a1 = buffer RLE
    const ra = c.cpu.r[31];
    c.imask = 0;
    c.cpu.sr &= ~@as(u32, 1);
    var n: u64 = 0;
    while (c.cpu.pc != ra and n < 50_000_000) : (n += 1) c.cpu.step(c);
    const hdr = std.mem.readInt(u32, c.ram[out..][0..4], .little);
    const words = hdr & 0xFFFF;
    std.debug.print("VLC isolado: {d} instr, header={x}, blocos={d} (macroblocos={d})\n", .{ n, hdr, countBlocks(&c.ram, out + 4, words), countBlocks(&c.ram, out + 4, words) / 6 });
}

pub fn main(init: std.process.Init) !void {
    const io = init.io;
    g_io = io;
    const arena = init.arena.allocator();
    const args = try init.minimal.args.toSlice(arena);
    if (args.len < 6) {
        std.debug.print("uso: psxweb-native <bios> <disco.bin> <exe> <frames> <out.ppm> [frame:mask...]\n", .{});
        return;
    }
    const bios = try Io.Dir.cwd().readFileAlloc(io, args[1], arena, .limited(1 << 20));
    g_disc = try Io.Dir.cwd().openFile(io, args[2], .{});
    const exe = try Io.Dir.cwd().readFileAlloc(io, args[3], arena, .limited(4 << 20));
    const frames = try std.fmt.parseInt(u32, args[4], 10);
    const bs_target: u32 = if (init.environ_map.get("BSHIT")) |v| try std.fmt.parseInt(u32, v, 10) else 1;

    const psx = &g_psx;
    psx.init(bios, readSector);

    // fast boot: roda a BIOS até o shell (0x80030000) e faz side-load do EXE
    var guard: u64 = 0;
    while (psx.cpu.pc != 0x80030000 and guard < 200_000_000) : (guard += 1) {
        psxmod.hleHooks(psx);
        psx.cpu.step(psx);
        if (psx.cycles >= psx.next_vblank) {
            psx.next_vblank += psxmod.CYCLES_PER_FRAME;
            psx.frame += 1;
            psx.raise(.vblank);
        }
    }
    std.debug.print("BIOS: shell em {d} instr, frame {d}\n", .{ guard, psx.frame });
    if (!psx.loadExe(exe)) return error.BadExe;
    if (init.environ_map.get("FMV") == null) std.debug.print("skip FMV patch: {}\n", .{psx.trapGunnerSkipFmv()});
    psx.watch_armed = true;
    psx.dbg_bs_target = bs_target;
    psx.dbg_clone = &g_clone;

    var wav: std.ArrayList(i16) = .empty;
    var f: u32 = 0;
    while (f < frames) : (f += 1) {
        for (args[6..]) |spec| {
            var it = std.mem.splitScalar(u8, spec, ':');
            const at = try std.fmt.parseInt(u32, it.next().?, 10);
            const mask = try std.fmt.parseInt(u16, it.next().?, 0);
            const hold: u32 = if (init.environ_map.get("HOLD")) |v| std.fmt.parseInt(u32, v, 10) catch 6 else 6;
            if (f >= at and f < at + hold) psx.sio.buttons[0] = 0xFFFF & ~mask;
            if (f == at + hold) psx.sio.buttons[0] = 0xFFFF;
        }
        if (f == 600) psx.sio.xlog_arm = true;
        psx.runFrame(psxmod.interpRun);
        while (psx.spu.out_r != psx.spu.out_w) : (psx.spu.out_r +%= 1) try wav.append(arena, psx.spu.out[psx.spu.out_r & 16383]);
        if (!g_clone_done and psx.dbg_bs_hits >= 1 and psx.dbg_clone_ready) {
            g_clone_done = true;
            g_clone = psx.dbg_clone.*;
            vlcExperiment();
        }
        if (psx.halted) {
            std.debug.print("PC inválido no frame {d}; últimos PCs:\n", .{f});
            var k: u32 = 0;
            while (k < 64) : (k += 1) std.debug.print("{x:0>8} ", .{psx.trace[(psx.trace_i +% k) & 63]});
            std.debug.print("\nsaltos:\n", .{});
            k = 0;
            while (k < 32) : (k += 1) {
                const j = psx.jumps[(psx.jump_i +% k) & 31];
                std.debug.print("{x:0>8}->{x:0>8}\n", .{ j[0], j[1] });
            }
            std.debug.print("watch_pc={x} watch_dma={d} madr1={x} bcr1={x} madr0={x}\n", .{ psx.watch_pc, psx.watch_dma, psx.dma_madr[1], psx.dma_bcr[1], psx.dma_madr[0] });
            std.debug.print("cause={x} epc={x} sr={x} ram80={x} {x} {x} {x}\n", .{ psx.cpu.cause, psx.cpu.epc, psx.cpu.sr, std.mem.readInt(u32, psx.ram[0x80..0x84], .little), std.mem.readInt(u32, psx.ram[0x84..0x88], .little), std.mem.readInt(u32, psx.ram[0x88..0x8C], .little), std.mem.readInt(u32, psx.ram[0x8C..0x90], .little) });
            std.debug.print("\nregs: ", .{});
            for (psx.cpu.r, 0..) |rv, ri| std.debug.print("r{d}={x} ", .{ ri, rv });
            std.debug.print("\n", .{});
            break;
        }
        if (f % 60 == 0) std.debug.print("frame {d} pc={x:0>8} disp={} mode={x} fmv_skips={d} fmv_ended={d}\n", .{ f, psx.cpu.pc, psx.gpu.disp_on, psx.gpu.disp_mode, psx.fmv_skips, psx.cdrom.fmv_ended });
    }
    std.debug.print("mdec: decodes={d} words={d} lastcmd={x} qt0={d} scale0={d}\n", .{ psx.mdec.dbg_decodes, psx.mdec.dbg_words, psx.mdec.dbg_lastcmd, psx.mdec.qt_y[0], psx.mdec.scale[0] });
    std.debug.print("dma kicks={any} chcrw={any} w0={d} first0={x} chcr0={x} chcr1={x}\n", .{ psx.dbg_dma, psx.dbg_chcr_writes, psx.dbg_dma_words0, psx.dbg_dma_first0, psx.dma_chcr[0], psx.dma_chcr[1] });
    for (psx.dbg_log[0..psx.dbg_log_len]) |e| std.debug.print("dma0 madr={x} bcr={x} chcr={x} | mdec cmd={x} need={d} len={d}\n", .{ e[0], e[1], e[2], e[3], e[4], e[5] });
    for (psx.cdrom.dbg[0..psx.cdrom.dbg_n]) |e| std.debug.print("cd cmd={x} p0={x} loc={d} frame={d}\n", .{ e[0], e[1], e[2], e[3] });
    for (psx.dbg_mw[0..psx.dbg_mw_n]) |e| std.debug.print("mdec write pc={x} v={x} ra={x}\n", .{ e[0], e[1], e[2] });
    for (psx.dbg_hw[0..psx.dbg_hw_n]) |e| std.debug.print("w1a pc={x} a={x} v={x}\n", .{ e[0], e[1], e[2] });
    std.debug.print("ram 1a0000: ", .{});
    for (0..8) |k| std.debug.print("{x:0>8} ", .{std.mem.readInt(u32, psx.ram[0x1a0000 + k * 4 ..][0..4], .little)});
    std.debug.print("\n", .{});
    for (psx.sio.xlog[0..psx.sio.xlog_n]) |e| std.debug.print("sio tx={x} rx={x} ack={d} ctrl={x} cyc={d}\n", .{ e[0], e[1], e[2], e[3], e[4] });
    for (psx.dbg_iop[0..psx.dbg_iop_n]) |e| std.debug.print("io read pc={x} off={x}\n", .{ e[0], e[1] });
    std.debug.print("sio: pad reads={d}\n", .{psx.sio.dbg_reads});
    std.debug.print("gpu ops:", .{});
    for (psx.gpu.dbg_ops, 0..) |n, op| if (n > 0) std.debug.print(" {x}:{d}", .{ op, n });
    std.debug.print("\nda=({d},{d})-({d},{d}) off=({d},{d})\n", .{ psx.gpu.da_x1, psx.gpu.da_y1, psx.gpu.da_x2, psx.gpu.da_y2, psx.gpu.off_x, psx.gpu.off_y });
    for (psx.gpu.dbg_cp[0..psx.gpu.dbg_cp_n]) |e| std.debug.print("copy src={x} dst={x} size={x}\n", .{ e[0], e[1], e[2] });
    {
        std.debug.print("sr={x} imask={x} istat={x} vsync_ctr={x} a0={x}\n", .{ psx.cpu.sr, psx.imask, psx.istat, std.mem.readInt(u32, psx.ram[0x10815C..][0..4], .little), psx.cpu.r[4] });
        std.debug.print("ultimos saltos:\n", .{});
        var k: u32 = 0;
        while (k < 32) : (k += 1) {
            const j = psx.jumps[(psx.jump_i +% k) & 31];
            std.debug.print("{x:0>8}->{x:0>8}\n", .{ j[0], j[1] });
        }
    }
    {
        const name = try std.fmt.allocPrint(arena, "{s}.wav", .{args[5]});
        const wf = try Io.Dir.cwd().createFile(io, name, .{});
        defer wf.close(io);
        var h: [44]u8 = undefined;
        const data_len: u32 = @intCast(wav.items.len * 2);
        @memcpy(h[0..4], "RIFF");
        std.mem.writeInt(u32, h[4..8], 36 + data_len, .little);
        @memcpy(h[8..16], "WAVEfmt ");
        std.mem.writeInt(u32, h[16..20], 16, .little);
        std.mem.writeInt(u16, h[20..22], 1, .little);
        std.mem.writeInt(u16, h[22..24], 2, .little);
        std.mem.writeInt(u32, h[24..28], 44100, .little);
        std.mem.writeInt(u32, h[28..32], 44100 * 4, .little);
        std.mem.writeInt(u16, h[32..34], 4, .little);
        std.mem.writeInt(u16, h[34..36], 16, .little);
        @memcpy(h[36..40], "data");
        std.mem.writeInt(u32, h[40..44], data_len, .little);
        try wf.writeStreamingAll(io, &h);
        try wf.writeStreamingAll(io, std.mem.sliceAsBytes(wav.items));
        std.debug.print("spu: voices kon, wav {d} samples\n", .{wav.items.len / 2});
    }
    std.debug.print("TTY:\n{s}\n", .{psx.tty[0..psx.tty_len]});

    // grava a VRAM inteira (1024x512) como PPM
    const out = try Io.Dir.cwd().createFile(io, args[5], .{});
    defer out.close(io);
    var hdr_buf: [32]u8 = undefined;
    try out.writeStreamingAll(io, try std.fmt.bufPrint(&hdr_buf, "P6\n1024 512\n255\n", .{}));
    const rgb = try arena.alloc(u8, 1024 * 512 * 3);
    for (psx.gpu.vram, 0..) |px, i| {
        rgb[i * 3 + 0] = @intCast((px & 0x1F) << 3);
        rgb[i * 3 + 1] = @intCast(((px >> 5) & 0x1F) << 3);
        rgb[i * 3 + 2] = @intCast(((px >> 10) & 0x1F) << 3);
    }
    try out.writeStreamingAll(io, rgb);
    {
        const scr = try arena.alloc(u8, 640 * 480 * 4);
        const d = psx.gpu.renderDisplay(scr);
        const name = try std.fmt.allocPrint(arena, "{s}.screen.ppm", .{args[5]});
        const so = try Io.Dir.cwd().createFile(io, name, .{});
        defer so.close(io);
        var hb: [32]u8 = undefined;
        try so.writeStreamingAll(io, try std.fmt.bufPrint(&hb, "P6\n{d} {d}\n255\n", .{ d.w, d.h }));
        const px = try arena.alloc(u8, d.w * d.h * 3);
        for (0..d.w * d.h) |i| {
            px[i * 3] = scr[i * 4];
            px[i * 3 + 1] = scr[i * 4 + 1];
            px[i * 3 + 2] = scr[i * 4 + 2];
        }
        try so.writeStreamingAll(io, px);
    }
    {
        const mf = try Io.Dir.cwd().createFile(io, "/private/tmp/claude-501/-Volumes-life-code-fun-Trap-Gunner/4c9538ba-fb9f-4c7d-8f03-894944cde628/scratchpad/mdec3.bin", .{});
        defer mf.close(io);
        try mf.writeStreamingAll(io, std.mem.sliceAsBytes(psx.mdec.dbg_frame[0..psx.mdec.dbg_frame_len]));
        const rl = try Io.Dir.cwd().createFile(io, "/private/tmp/claude-501/-Volumes-life-code-fun-Trap-Gunner/4c9538ba-fb9f-4c7d-8f03-894944cde628/scratchpad/rle1.bin", .{});
        defer rl.close(io);
        try rl.writeStreamingAll(io, std.mem.sliceAsBytes(psx.mdec.dbg_rle[0..psx.mdec.dbg_rle_len]));
    }
    {
        std.debug.print("bitstream addr={x} frame={d} hits={d} decode_frame={d}\n", .{ psx.dbg_bs_addr, psx.dbg_bs_frame, psx.dbg_bs_hits, psx.dbg_dec_frame });
        const bf = try Io.Dir.cwd().createFile(io, "/private/tmp/claude-501/-Volumes-life-code-fun-Trap-Gunner/4c9538ba-fb9f-4c7d-8f03-894944cde628/scratchpad/bs1.bin", .{});
        defer bf.close(io);
        try bf.writeStreamingAll(io, &psx.dbg_bs);
        const rf = try Io.Dir.cwd().createFile(io, "/private/tmp/claude-501/-Volumes-life-code-fun-Trap-Gunner/4c9538ba-fb9f-4c7d-8f03-894944cde628/scratchpad/ramsnap.bin", .{});
        defer rf.close(io);
        try rf.writeStreamingAll(io, &psx.dbg_ramsnap);
    }
    for (psx.cdrom.dlog[0..psx.cdrom.dlog_n]) |e| std.debug.print("load lba={d} prevpos={d}/{d} mode={x}\n", .{ e[0], e[1], e[2], e[3] });
    for (psx.dbg_d3[0..psx.dbg_d3_n]) |e| std.debug.print("dma3 lba={d} addr={x} words={d} fifo_pos={d}\n", .{ e[0], e[1], e[2], e[3] });
    std.debug.print("mdec1 active={} left={d} out={d}/{d} in={d}/{d} cmd={x} kicks={any}\n", .{ psx.mdec1_active, psx.mdec1_left, psx.mdec.out_pos, psx.mdec.out_len, psx.mdec.in_len, psx.mdec.in_need, psx.mdec.cmd, psx.dbg_dma });
    std.debug.print("display x={d} y={d} {d}x{d}\n", .{ psx.gpu.disp_x, psx.gpu.disp_y, psx.gpu.displaySize().w, psx.gpu.displaySize().h });
}

test "cpu basic addiu" {
    const p = &g_psx;
    const zb: [4]u8 = @splat(0);
    p.init(&zb, readSector);
    // addiu $t0, $zero, 5 ; em RAM
    std.mem.writeInt(u32, p.ram[0..4], 0x24080005, .little);
    p.cpu.pc = 0x80000000;
    p.cpu.next_pc = 0x80000004;
    p.cpu.step(p);
    try std.testing.expectEqual(@as(u32, 5), p.cpu.r[8]);
}
