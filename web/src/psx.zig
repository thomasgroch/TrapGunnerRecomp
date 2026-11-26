//! Máquina PS1: barramento, IRQ, DMA, timers e laço de frames.
//! Sem alocação: tudo vive dentro da struct (cabe na memória do wasm).
const std = @import("std");
pub const Cpu = @import("cpu.zig").Cpu;
pub const Gpu = @import("gpu.zig").Gpu;
pub const Gte = @import("gte.zig").Gte;
pub const Cdrom = @import("cdrom.zig").Cdrom;
pub const Sio = @import("sio.zig").Sio;
pub const Mdec = @import("mdec.zig").Mdec;

pub const RAM_SIZE = 2 * 1024 * 1024;
pub const BIOS_SIZE = 512 * 1024;
pub const CYCLES_PER_FRAME: u64 = 33868800 / 60;

pub const Irq = enum(u4) { vblank = 0, gpu = 1, cdrom = 2, dma = 3, tmr0 = 4, tmr1 = 5, tmr2 = 6, pad = 7, sio = 8, spu = 9 };

/// Função que o host fornece para ler setores brutos (2352 bytes) do disco.
pub const SectorReader = *const fn (lba: u32, out: *[2352]u8) bool;

pub const Psx = struct {
    ram: [RAM_SIZE]u8 = undefined,
    bios: [BIOS_SIZE]u8 = undefined,
    scratch: [1024]u8 = undefined,
    cpu: Cpu = .{},
    gpu: Gpu = .{},
    gte: Gte = .{},
    cdrom: Cdrom = .{},
    sio: Sio = .{},
    mdec: Mdec = .{},

    cycles: u64 = 0,
    frame: u64 = 0,
    next_vblank: u64 = CYCLES_PER_FRAME,
    istat: u32 = 0,
    imask: u32 = 0,

    // DMA
    dpcr: u32 = 0x07654321,
    dicr: u32 = 0,
    dma_madr: [7]u32 = @splat(0),
    dma_bcr: [7]u32 = @splat(0),
    dma_chcr: [7]u32 = @splat(0),

    // timers (aproximados)
    tmr_count: [3]u32 = @splat(0),
    tmr_mode: [3]u32 = @splat(0),
    tmr_target: [3]u32 = @splat(0),
    tmr_last: u64 = 0,

    spu_regs: [512]u16 = @splat(0),
    tty: [4096]u8 = undefined,
    tty_len: usize = 0,

    /// Hook opcional do recompilador: código invalidado quando a RAM muda.
    code_write_hook: ?*const fn (addr: u32) void = null,
    // depuração: últimos PCs executados
    trace: [64]u32 = @splat(0),
    jumps: [32][2]u32 = @splat(.{ 0, 0 }),
    jump_i: u32 = 0,
    last_pc: u32 = 0,
    trace_i: u32 = 0,
    halted: bool = false,
    watch_pc: u32 = 0,
    watch_dma: i32 = -1,
    watch_armed: bool = false,
    dbg_dma: [7]u32 = @splat(0),
    dbg_dma_words0: u32 = 0,
    dbg_log: [16][6]u32 = undefined,
    dbg_log_len: u32 = 0,
    dbg_mw: [8][3]u32 = undefined,
    dbg_mw_n: u32 = 0,
    dbg_hw: [8][3]u32 = undefined,
    dbg_hw_n: u32 = 0,
    dbg_bs_hits: u32 = 0,
    dbg_bs_target: u32 = 1,
    dbg_clone: *Psx = undefined,
    dbg_clone_ready: bool = false,
    dbg_bs_frame: u64 = 0,
    mdec1_active: bool = false,
    dbg_iop: [32][2]u32 = undefined,
    dbg_iop_n: u32 = 0,
    mdec1_stall: u32 = 0,
    mdec_in_seen: u64 = 0,
    mdec_last_in: u64 = 0,
    fmv_skips: u32 = 0,
    fmv_watchdog: bool = false,
    dbg_dec_snap: bool = false,
    dbg_dec_frame: u64 = 0,
    mdec1_left: u32 = 0,
    mdec1_addr: u32 = 0,
    dbg_d3: [40][4]u32 = undefined,
    dbg_d3_n: u32 = 0,
    dbg_bs: [16384]u8 = undefined,
    dbg_bs_addr: u32 = 0,
    dbg_ramsnap: [RAM_SIZE]u8 = undefined,
    dbg_dma_first0: u32 = 0,
    dbg_chcr_writes: [7]u32 = @splat(0),

    pub fn init(self: *Psx, bios: []const u8, reader: SectorReader) void {
        self.* = .{};
        @memset(&self.ram, 0);
        @memset(&self.scratch, 0);
        @memcpy(self.bios[0..@min(bios.len, BIOS_SIZE)], bios[0..@min(bios.len, BIOS_SIZE)]);
        self.cdrom.reader = reader;
        self.gpu.reset();
        self.gte = .{};
    }

    pub fn raise(self: *Psx, irq: Irq) void {
        self.istat |= @as(u32, 1) << @intFromEnum(irq);
    }
    pub fn irqPending(self: *Psx) bool {
        return (self.istat & self.imask) != 0;
    }

    inline fn phys(addr: u32) u32 {
        const seg = addr >> 29;
        return switch (seg) {
            4 => addr & 0x7FFFFFFF, // KSEG0
            5 => addr & 0x1FFFFFFF, // KSEG1
            else => addr,
        };
    }

    pub fn fetch(self: *Psx, addr: u32) u32 {
        return self.read32(addr);
    }

    // ---------------- leitura ----------------
    pub fn read32(self: *Psx, addr: u32) u32 {
        const a = phys(addr);
        if (a < 0x00800000) return std.mem.readInt(u32, self.ram[a & (RAM_SIZE - 1) ..][0..4], .little);
        if (a >= 0x1F800000 and a < 0x1F800400) return std.mem.readInt(u32, self.scratch[a & 0x3FF ..][0..4], .little);
        if (a >= 0x1FC00000 and a < 0x1FC80000) return std.mem.readInt(u32, self.bios[a & (BIOS_SIZE - 1) ..][0..4], .little);
        if (a >= 0x1F801000 and a < 0x1F803000) return self.io_read(a, 4);
        return 0;
    }
    pub fn read16(self: *Psx, addr: u32) u16 {
        const a = phys(addr);
        if (a < 0x00800000) return std.mem.readInt(u16, self.ram[a & (RAM_SIZE - 1) ..][0..2], .little);
        if (a >= 0x1F800000 and a < 0x1F800400) return std.mem.readInt(u16, self.scratch[a & 0x3FF ..][0..2], .little);
        if (a >= 0x1FC00000 and a < 0x1FC80000) return std.mem.readInt(u16, self.bios[a & (BIOS_SIZE - 1) ..][0..2], .little);
        if (a >= 0x1F801000 and a < 0x1F803000) return @truncate(self.io_read(a, 2));
        return 0;
    }
    pub fn read8(self: *Psx, addr: u32) u8 {
        const a = phys(addr);
        if (a < 0x00800000) return self.ram[a & (RAM_SIZE - 1)];
        if (a >= 0x1F800000 and a < 0x1F800400) return self.scratch[a & 0x3FF];
        if (a >= 0x1FC00000 and a < 0x1FC80000) return self.bios[a & (BIOS_SIZE - 1)];
        if (a >= 0x1F801000 and a < 0x1F803000) return @truncate(self.io_read(a, 1));
        if (a >= 0x1F000000 and a < 0x1F800000) return 0xFF; // expansão 1 vazia
        return 0;
    }

    // ---------------- escrita ----------------
    pub fn write32(self: *Psx, addr: u32, v: u32) void {
        const a = phys(addr);
        if (a < 0x00800000) {
            if (self.watch_armed and (a & (RAM_SIZE - 1)) < 0x100 and self.watch_pc == 0) self.watch_pc = self.cpu.cur_pc;
            if (self.dbg_hw_n < 8 and (a & 0x1FFFFC) == 0x1a0000) {
                self.dbg_hw[self.dbg_hw_n] = .{ self.cpu.cur_pc, a, @as(u32, v) };
                self.dbg_hw_n += 1;
            }
            std.mem.writeInt(u32, self.ram[a & (RAM_SIZE - 1) ..][0..4], v, .little);
            if (self.code_write_hook) |h| h(a & (RAM_SIZE - 1));
            return;
        }
        if (a >= 0x1F800000 and a < 0x1F800400) return std.mem.writeInt(u32, self.scratch[a & 0x3FF ..][0..4], v, .little);
        if (a >= 0x1F801000 and a < 0x1F803000) return self.io_write(a, v, 4);
    }
    pub fn write16(self: *Psx, addr: u32, v: u16) void {
        const a = phys(addr);
        if (a < 0x00800000) {
            if (self.watch_armed and (a & (RAM_SIZE - 1)) < 0x100 and self.watch_pc == 0) self.watch_pc = self.cpu.cur_pc;
            if (self.dbg_hw_n < 8 and (a & 0x1FFFFC) == 0x1a0000) {
                self.dbg_hw[self.dbg_hw_n] = .{ self.cpu.cur_pc, a, @as(u32, v) };
                self.dbg_hw_n += 1;
            }
            std.mem.writeInt(u16, self.ram[a & (RAM_SIZE - 1) ..][0..2], v, .little);
            if (self.code_write_hook) |h| h(a & (RAM_SIZE - 1));
            return;
        }
        if (a >= 0x1F800000 and a < 0x1F800400) return std.mem.writeInt(u16, self.scratch[a & 0x3FF ..][0..2], v, .little);
        if (a >= 0x1F801000 and a < 0x1F803000) return self.io_write(a, v, 2);
    }
    pub fn write8(self: *Psx, addr: u32, v: u8) void {
        const a = phys(addr);
        if (a < 0x00800000) {
            if (self.watch_armed and (a & (RAM_SIZE - 1)) < 0x100 and self.watch_pc == 0) self.watch_pc = self.cpu.cur_pc;
            if (self.dbg_hw_n < 8 and (a & 0x1FFFFC) == 0x1a0000) {
                self.dbg_hw[self.dbg_hw_n] = .{ self.cpu.cur_pc, a, @as(u32, v) };
                self.dbg_hw_n += 1;
            }
            self.ram[a & (RAM_SIZE - 1)] = v;
            if (self.code_write_hook) |h| h(a & (RAM_SIZE - 1));
            return;
        }
        if (a >= 0x1F800000 and a < 0x1F800400) {
            self.scratch[a & 0x3FF] = v;
            return;
        }
        if (a >= 0x1F802000 and a < 0x1F802100) {
            // porta de debug / POST (0x1F802041) e TTY da expansão 2 (0x1F802023)
            if (a == 0x1F802023 or a == 0x1F802080) self.putc(v);
            return;
        }
        if (a >= 0x1F801000 and a < 0x1F803000) return self.io_write(a, v, 1);
    }

    pub fn putc(self: *Psx, c: u8) void {
        if (self.tty_len < self.tty.len) {
            self.tty[self.tty_len] = c;
            self.tty_len += 1;
        }
    }

    // ---------------- I/O ----------------
    fn io_read(self: *Psx, a: u32, size: u8) u32 {
        const off = a - 0x1F801000;
        if (self.sio.xlog_arm and (off == 0x44 or off == 0x70 or off == 0x40) and self.dbg_iop_n < 32) {
            var seen = false;
            for (self.dbg_iop[0..self.dbg_iop_n]) |e| {
                if (e[0] == self.cpu.cur_pc) seen = true;
            }
            if (!seen) {
                self.dbg_iop[self.dbg_iop_n] = .{ self.cpu.cur_pc, off };
                self.dbg_iop_n += 1;
            }
        }
        switch (off) {
            0x040...0x04F => return self.sio.read(off - 0x40, size),
            0x070 => return self.istat,
            0x074 => return self.imask,
            0x080...0x0EF => {
                const ch = (off - 0x80) >> 4;
                return switch (off & 0xF) {
                    0 => self.dma_madr[ch],
                    4 => self.dma_bcr[ch],
                    8 => self.dma_chcr[ch],
                    else => 0,
                };
            },
            0x0F0 => return self.dpcr,
            0x0F4 => return self.dicr,
            0x100...0x12F => {
                self.updateTimers();
                const t = (off - 0x100) >> 4;
                return switch (off & 0xF) {
                    0 => self.tmr_count[t],
                    4 => blk: {
                        const m = self.tmr_mode[t];
                        self.tmr_mode[t] &= ~@as(u32, 0x1800); // bits de "atingiu" limpam na leitura
                        break :blk m;
                    },
                    8 => self.tmr_target[t],
                    else => 0,
                };
            },
            0x800...0x803 => {
                if (off == 0x802 and size >= 2) {
                    const lo: u32 = self.cdrom.read(2, self);
                    const hi: u32 = self.cdrom.read(2, self);
                    return lo | (hi << 8);
                }
                return self.cdrom.read(@truncate(off - 0x800), self);
            },
            0x810 => return self.gpu.gpuread(),
            0x814 => return self.gpu.status(self.frame),
            0x820 => return self.mdec.readData(),
            0x824 => return self.mdec.status(),
            0xC00...0xFFF => {
                const idx = (off - 0xC00) >> 1;
                if (off == 0xDAE) return self.spu_regs[(0xDAA - 0xC00) >> 1] & 0x3F; // SPUSTAT espelha SPUCNT
                return self.spu_regs[idx];
            },
            else => return 0,
        }
    }

    fn io_write(self: *Psx, a: u32, v: u32, size: u8) void {
        const off = a - 0x1F801000;
        switch (off) {
            0x040...0x04F => self.sio.write(off - 0x40, v, size, self),
            0x070 => self.istat &= v,
            0x074 => self.imask = v & 0x7FF,
            0x080...0x0EF => {
                const ch = (off - 0x80) >> 4;
                if (size == 2 and (off & 2) != 0) {
                    // metade alta de MADR/BCR/CHCR
                    switch (off & 0xC) {
                        0 => self.dma_madr[ch] = (self.dma_madr[ch] & 0xFFFF) | ((v & 0xFF) << 16),
                        4 => self.dma_bcr[ch] = (self.dma_bcr[ch] & 0xFFFF) | ((v & 0xFFFF) << 16),
                        8 => {
                            self.dma_chcr[ch] = (self.dma_chcr[ch] & 0xFFFF) | ((v & 0xFFFF) << 16);
                            self.dmaKick(ch);
                        },
                        else => {},
                    }
                    return;
                }
                const val = if (size == 2) switch (off & 0xC) {
                    0 => (self.dma_madr[ch] & 0xFFFF0000) | (v & 0xFFFF),
                    4 => (self.dma_bcr[ch] & 0xFFFF0000) | (v & 0xFFFF),
                    8 => (self.dma_chcr[ch] & 0xFFFF0000) | (v & 0xFFFF),
                    else => v,
                } else v;
                switch (off & 0xC) {
                    0 => self.dma_madr[ch] = val & 0xFFFFFF,
                    4 => self.dma_bcr[ch] = val,
                    8 => {
                        self.dbg_chcr_writes[ch] += 1;
                        self.dma_chcr[ch] = val;
                        self.dmaKick(ch);
                    },
                    else => {},
                }
            },
            0x0F0 => self.dpcr = v,
            0x0F4 => {
                // bits 24-30 escritos com 1 limpam os flags
                const flags = (self.dicr & 0x7F000000) & ~(v & 0x7F000000);
                self.dicr = (v & 0x00FF803F) | flags;
                self.updateDicrMaster();
            },
            0x100...0x12F => {
                self.updateTimers();
                const t = (off - 0x100) >> 4;
                switch (off & 0xF) {
                    0 => self.tmr_count[t] = v & 0xFFFF,
                    4 => {
                        self.tmr_mode[t] = (v & 0x3FF) | 0x400;
                        self.tmr_count[t] = 0;
                    },
                    8 => self.tmr_target[t] = v & 0xFFFF,
                    else => {},
                }
            },
            0x800...0x803 => self.cdrom.write(@truncate(off - 0x800), @truncate(v), self),
            0x810 => self.gpu.gp0(v, self),
            0x820 => {
                if (self.dbg_mw_n < 8) {
                    self.dbg_mw[self.dbg_mw_n] = .{ self.cpu.cur_pc, v, self.cpu.r[31] };
                    self.dbg_mw_n += 1;
                }
                self.mdec.writeData(v);
                self.mdec_in_seen +%= 1;
                self.mdecOutPump();
            },
            0x824 => {
                self.mdec.control(v);
                if (v & 0x80000000 != 0) self.mdec1_active = false;
            },
            0x814 => self.gpu.gp1(v),
            0xC00...0xFFF => {
                const idx = (off - 0xC00) >> 1;
                self.spu_regs[idx] = @truncate(v);
                if (size == 4 and idx + 1 < self.spu_regs.len) self.spu_regs[idx + 1] = @truncate(v >> 16);
            },
            else => {},
        }
    }

    // ---------------- DMA ----------------
    fn updateDicrMaster(self: *Psx) void {
        const force = (self.dicr >> 15) & 1;
        const en = (self.dicr >> 23) & 1;
        const flags = (self.dicr >> 24) & 0x7F;
        const mask = (self.dicr >> 16) & 0x7F;
        const master = force != 0 or (en != 0 and (flags & mask) != 0);
        const was = (self.dicr >> 31) != 0;
        if (master) self.dicr |= 1 << 31 else self.dicr &= ~@as(u32, 1 << 31);
        if (master and !was) self.raise(.dma);
    }

    fn dmaDone(self: *Psx, ch: u32) void {
        self.dma_chcr[ch] &= ~@as(u32, 0x01000000);
        if ((self.dicr >> @intCast(16 + ch)) & 1 != 0) self.dicr |= @as(u32, 1) << @intCast(24 + ch);
        self.updateDicrMaster();
    }

    fn dmaKick(self: *Psx, ch: u32) void {
        const c = self.dma_chcr[ch];
        if (c & 0x01000000 == 0) return;
        const sync = (c >> 9) & 3;
        self.dbg_dma[ch] += 1;
        if (ch == 0 and self.dbg_log_len < 16) {
            self.dbg_log[self.dbg_log_len] = .{ self.dma_madr[0], self.dma_bcr[0], c, self.mdec.cmd, self.mdec.in_need, self.mdec.in_len };
            self.dbg_log_len += 1;
        }
        if (sync == 0 and c & 0x10000000 == 0 and ch != 6) return; // modo manual exige trigger
        const to_ram = c & 1 == 0;
        const step: u32 = if (c & 2 != 0) @bitCast(@as(i32, -4)) else 4;
        var addr = self.dma_madr[ch] & 0x1FFFFC;
        switch (ch) {
            6 => { // OTC: tabela de ordenação invertida
                var n = self.dma_bcr[ch] & 0xFFFF;
                if (n == 0) n = 0x10000;
                while (n > 0) : (n -= 1) {
                    const val: u32 = if (n == 1) 0xFFFFFF else (addr -% 4) & 0x1FFFFF;
                    std.mem.writeInt(u32, self.ram[addr..][0..4], val, .little);
                    addr = (addr -% 4) & 0x1FFFFC;
                }
            },
            2 => {
                if (sync == 2) { // lista ligada
                    var guard: u32 = 0;
                    while (guard < 0x40000) : (guard += 1) {
                        const hdr = std.mem.readInt(u32, self.ram[addr..][0..4], .little);
                        const n = hdr >> 24;
                        var k: u32 = 0;
                        while (k < n) : (k += 1) {
                            addr = (addr + 4) & 0x1FFFFC;
                            self.gpu.gp0(std.mem.readInt(u32, self.ram[addr..][0..4], .little), self);
                        }
                        if (hdr & 0x800000 != 0) break;
                        addr = hdr & 0x1FFFFC;
                    }
                } else {
                    const words = self.blockWords(ch, sync);
                    var k: u32 = 0;
                    while (k < words) : (k += 1) {
                        if (to_ram) {
                            std.mem.writeInt(u32, self.ram[addr..][0..4], self.gpu.gpuread(), .little);
                        } else {
                            self.gpu.gp0(std.mem.readInt(u32, self.ram[addr..][0..4], .little), self);
                        }
                        addr = (addr +% step) & 0x1FFFFC;
                    }
                }
            },
            3 => {
                const words = self.blockWords(ch, sync);
                if (self.cdrom.cur_lba >= 10515 and self.cdrom.cur_lba < 10530 and self.dbg_d3_n < 40) {
                    self.dbg_d3[self.dbg_d3_n] = .{ self.cdrom.cur_lba, addr, words, self.cdrom.data_pos };
                    self.dbg_d3_n += 1;
                }
                var k: u32 = 0;
                while (k < words) : (k += 1) {
                    std.mem.writeInt(u32, self.ram[addr..][0..4], self.cdrom.dataWord(), .little);
                    addr = (addr +% step) & 0x1FFFFC;
                }
            },
            0 => { // RAM -> MDEC
                const words = self.blockWords(ch, sync);
                if (!self.dbg_dec_snap and (self.mdec.cmd >> 29) == 1) {
                    self.dbg_dec_snap = true;
                    self.dbg_ramsnap = self.ram;
                    self.dbg_dec_frame = self.frame;
                }
                self.dbg_dma_words0 = words;
                self.dbg_dma_first0 = std.mem.readInt(u32, self.ram[addr..][0..4], .little);
                var k: u32 = 0;
                while (k < words) : (k += 1) {
                    self.mdec.writeData(std.mem.readInt(u32, self.ram[addr..][0..4], .little));
                    self.mdec_in_seen +%= 1;
                    addr = (addr +% step) & 0x1FFFFC;
                }
                self.mdecOutPump();
            },
            1 => { // MDEC -> RAM: anda conforme o MDEC produz (DREQ); senão fica pendente
                if (!self.mdec1_active) {
                    self.mdec1_active = true;
                    self.mdec1_left = self.blockWords(ch, sync);
                    self.mdec1_addr = addr;
                }
                self.mdecOutPump();
                return;
            },
            else => {}, // SPU/PIO: só completa
        }
        if (self.watch_armed and self.watch_dma < 0 and std.mem.readInt(u32, self.ram[0x80..0x84], .little) == 0) self.watch_dma = @intCast(ch);
        self.dmaDone(ch);
    }

    /// Pulo de FMV: se o DMA de saída do MDEC está esperando dados que nunca
    /// virão (sem entrada nova por 3 frames), completa com pixels pretos.
    fn mdecWatchdog(self: *Psx) void {
        if (!self.fmv_watchdog) return;
        if (!self.mdec1_active or self.mdec.out_pos < self.mdec.out_len) {
            self.mdec1_stall = 0;
            return;
        }
        if (self.mdec_in_seen != self.mdec_last_in) {
            self.mdec_last_in = self.mdec_in_seen;
            self.mdec1_stall = 0;
            return;
        }
        self.mdec1_stall += 1;
        if (self.mdec1_stall < 3) return;
        const step: u32 = if (self.dma_chcr[1] & 2 != 0) @bitCast(@as(i32, -4)) else 4;
        while (self.mdec1_left > 0) : (self.mdec1_left -= 1) {
            std.mem.writeInt(u32, self.ram[self.mdec1_addr..][0..4], 0, .little);
            self.mdec1_addr = (self.mdec1_addr +% step) & 0x1FFFFC;
        }
        self.mdec1_active = false;
        self.mdec1_stall = 0;
        self.fmv_skips += 1;
        self.dmaDone(1);
    }

    /// Continua o DMA1 pendente com os dados que o MDEC já tem.
    pub fn mdecOutPump(self: *Psx) void {
        if (!self.mdec1_active) return;
        const step: u32 = if (self.dma_chcr[1] & 2 != 0) @bitCast(@as(i32, -4)) else 4;
        while (self.mdec1_left > 0 and self.mdec.out_pos < self.mdec.out_len) : (self.mdec1_left -= 1) {
            std.mem.writeInt(u32, self.ram[self.mdec1_addr..][0..4], self.mdec.readData(), .little);
            self.mdec1_addr = (self.mdec1_addr +% step) & 0x1FFFFC;
        }
        self.dma_madr[1] = self.mdec1_addr;
        if (self.mdec1_left == 0) {
            self.mdec1_active = false;
            self.dmaDone(1);
        }
    }

    fn blockWords(self: *Psx, ch: u32, sync: u32) u32 {
        const bcr = self.dma_bcr[ch];
        if (sync == 0) {
            const n = bcr & 0xFFFF;
            return if (n == 0) 0x10000 else n;
        }
        return (bcr & 0xFFFF) * (bcr >> 16);
    }

    // ---------------- timers ----------------
    fn updateTimers(self: *Psx) void {
        const elapsed = self.cycles - self.tmr_last;
        if (elapsed == 0) return;
        self.tmr_last = self.cycles;
        for (0..3) |t| {
            const mode = self.tmr_mode[t];
            const src = (mode >> 8) & 3;
            var ticks: u64 = elapsed;
            if (t == 1 and (src & 1) != 0) ticks = elapsed / 2146 // hblank
            else if (t == 2 and (src & 2) != 0) ticks = elapsed / 8
            else if (t == 0 and (src & 1) != 0) ticks = elapsed / 5; // dotclock aproximado
            var c: u64 = self.tmr_count[t] + ticks;
            const target: u64 = if (self.tmr_target[t] == 0) 0x10000 else self.tmr_target[t];
            var hit = false;
            if (mode & 8 != 0) { // reset no target
                if (c >= target) {
                    c %= target;
                    hit = true;
                    self.tmr_mode[t] |= 0x800;
                }
            } else if (c >= 0x10000) {
                c &= 0xFFFF;
                self.tmr_mode[t] |= 0x1000;
                hit = (mode & 0x20) != 0;
            }
            if (hit and (mode & 0x30) != 0) self.raise(@enumFromInt(4 + t));
            self.tmr_count[t] = @truncate(c & 0xFFFF);
        }
    }

    // ---------------- laço ----------------
    /// Roda até o próximo VBLANK (um frame). `runner` executa CPU por um orçamento.
    pub fn runFrame(self: *Psx, comptime runner: anytype) void {
        while (self.cycles < self.next_vblank) {
            runner(self, self.next_vblank);
            self.cdrom.tick(self);
            self.sio.tick(self);
        }
        self.next_vblank += CYCLES_PER_FRAME;
        self.frame += 1;
        self.raise(.vblank);
        self.mdecWatchdog();
        self.updateTimers();
    }

    /// Patch protegido em RAM: só escreve se as palavras atuais forem as esperadas.
    pub fn patchWords(self: *Psx, addr: u32, expected: []const u32, replace: []const u32) bool {
        const a = addr & 0x1FFFFF;
        for (expected, 0..) |w, i| {
            if (std.mem.readInt(u32, self.ram[a + i * 4 ..][0..4], .little) != w) return false;
        }
        for (replace, 0..) |w, i| std.mem.writeInt(u32, self.ram[a + i * 4 ..][0..4], w, .little);
        return true;
    }

    /// Trap Gunner (SLUS-00679): pular FMVs. No laço do player (tarefa em
    /// 0x8001C490), a primeira busca de quadro (`jal 0x8001CBD8` em
    /// 0x8001C584) vira `j 0x8001C79C`, o caminho de saída/limpeza do próprio
    /// player — o mesmo que ele toma quando o vídeo termina.
    pub fn trapGunnerSkipFmv(self: *Psx) bool {
        return self.patchWords(0x8001C584, &.{0x0C0072F6}, &.{0x080071E7});
    }

    /// Carrega um PS-X EXE na RAM e aponta a CPU para a entrada (side-load).
    pub fn loadExe(self: *Psx, exe: []const u8) bool {
        if (exe.len < 0x800 or !std.mem.eql(u8, exe[0..8], "PS-X EXE")) return false;
        const pc = std.mem.readInt(u32, exe[0x10..0x14], .little);
        const gp = std.mem.readInt(u32, exe[0x14..0x18], .little);
        const dest = std.mem.readInt(u32, exe[0x18..0x1C], .little);
        const size = std.mem.readInt(u32, exe[0x1C..0x20], .little);
        const sp_base = std.mem.readInt(u32, exe[0x30..0x34], .little);
        const sp_off = std.mem.readInt(u32, exe[0x34..0x38], .little);
        const d = dest & 0x1FFFFF;
        const n = @min(size, exe.len - 0x800);
        @memcpy(self.ram[d .. d + n], exe[0x800 .. 0x800 + n]);
        self.cpu.pc = pc;
        self.cpu.next_pc = pc +% 4;
        self.cpu.r[28] = gp;
        if (sp_base != 0) {
            self.cpu.r[29] = sp_base +% sp_off;
            self.cpu.r[30] = sp_base +% sp_off;
        }
        return true;
    }
};

/// Executor de referência: interpretador até o orçamento de ciclos.
pub fn interpRun(psx: *Psx, until: u64) void {
    var n: u32 = 0;
    while (psx.cycles < until and n < 256) : (n += 1) {
        hleHooks(psx);
        const pc = psx.cpu.pc;
        psx.trace[psx.trace_i & 63] = pc;
        if (pc != psx.last_pc +% 4) {
            psx.jumps[psx.jump_i & 31] = .{ psx.last_pc, pc };
            psx.jump_i +%= 1;
        }
        psx.last_pc = pc;
        if (pc == 0x8009f4e4) {
            psx.dbg_bs_hits += 1;
            if (psx.dbg_bs_hits == psx.dbg_bs_target) {
                const a = psx.cpu.r[4] & 0x1FFFFF;
                psx.dbg_bs_addr = a;
                psx.dbg_bs_frame = psx.frame;
                @memcpy(&psx.dbg_bs, psx.ram[a .. a + 16384]);
                if (!psx.dbg_clone_ready and psx.dbg_bs_hits == 1) {
                    psx.dbg_clone.* = psx.*;
                    psx.dbg_clone_ready = true;
                }
            }
        }
        psx.trace_i +%= 1;
        const seg = pc & 0x1FFFFFFF;
        if (!psx.halted and !(seg < 0x200000 or (seg >= 0x1FC00000 and seg < 0x1FC80000))) {
            psx.halted = true;
        }
        psx.cpu.step(psx);
        if (psx.sio.irq_at != 0 and psx.cycles >= psx.sio.irq_at) psx.sio.tick(psx);
    }
}

/// Captura a saída de texto do kernel (A0:3C putchar, B0:3D putchar).
pub fn hleHooks(psx: *Psx) void {
    const pc = psx.cpu.pc & 0x1FFFFFFF;
    if (pc == 0xA0 and psx.cpu.r[9] == 0x3C) psx.putc(@truncate(psx.cpu.r[4]));
    if (pc == 0xB0 and psx.cpu.r[9] == 0x3D) psx.putc(@truncate(psx.cpu.r[4]));
}
