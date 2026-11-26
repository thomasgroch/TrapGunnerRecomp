//! R3000A (MIPS I) — interpretador de referência.
//! Ele é o gabarito: o recompilador MIPS→wasm tem que produzir o mesmo
//! estado. Implementa delay slots de branch e de load, COP0 (exceções e
//! interrupções) e encaminha COP2 para o GTE.
const std = @import("std");
const Psx = @import("psx.zig").Psx;

pub const Exc = enum(u5) {
    int = 0,
    adel = 4,
    ades = 5,
    syscall = 8,
    brk = 9,
    ri = 10,
    cpu = 11,
    ov = 12,
};

pub const Cpu = struct {
    r: [32]u32 = @splat(0),
    hi: u32 = 0,
    lo: u32 = 0,
    pc: u32 = 0xBFC00000,
    next_pc: u32 = 0xBFC00004,
    cur_pc: u32 = 0,
    // load delay: valor pendente que só aparece no registrador depois da próxima instrução
    ld_reg: u5 = 0,
    ld_val: u32 = 0,
    in_delay: bool = false,
    branch_taken: bool = false,
    // COP0
    sr: u32 = 0x10900000,
    cause: u32 = 0,
    epc: u32 = 0,
    badv: u32 = 0,
    branch_taken_prev: bool = false,
    pend_reg: u5 = 0,
    pend_val: u32 = 0,
    last_write: u5 = 0,

    pub fn reset(self: *Cpu) void {
        self.* = .{};
    }

    inline fn setReg(self: *Cpu, i: u5, v: u32) void {
        self.r[i] = v;
        self.r[0] = 0;
    }

    /// Escreve um registrador respeitando o load delay em curso.
    inline fn wr(self: *Cpu, out: *[32]u32, i: u5, v: u32) void {
        self.last_write = i;
        out[i] = v;
        out[0] = 0;
    }

    pub fn exception(self: *Cpu, e: Exc) void {
        // empilha os modos KU/IE (bits 0-5)
        const mode = self.sr & 0x3F;
        self.sr = (self.sr & ~@as(u32, 0x3F)) | ((mode << 2) & 0x3F);
        self.cause = (self.cause & ~@as(u32, 0x7C)) | (@as(u32, @intFromEnum(e)) << 2);
        if (self.in_delay) {
            self.epc = self.cur_pc -% 4;
            self.cause |= 1 << 31;
        } else {
            self.epc = self.cur_pc;
            self.cause &= ~@as(u32, 1 << 31);
        }
        const vec: u32 = if (self.sr & (1 << 22) != 0) 0xBFC00180 else 0x80000080;
        self.pc = vec;
        self.next_pc = vec +% 4;
    }

    /// Executa uma instrução.
    pub fn step(self: *Cpu, psx: *Psx) void {
        // interrupção pendente?
        if (psx.irqPending()) self.cause |= 1 << 10 else self.cause &= ~@as(u32, 1 << 10);
        if ((self.sr & 1) != 0 and (self.sr & self.cause & 0xFF00) != 0) {
            // GTE: a instrução no PC não é executada antes da exceção, a menos que seja COP2 cmd
            self.cur_pc = self.pc;
            self.in_delay = self.branch_taken_prev;
            self.exception(.int);
            self.flushLoad();
            return;
        }

        self.cur_pc = self.pc;
        if (self.pc & 3 != 0) {
            self.badv = self.pc;
            self.exception(.adel);
            return;
        }
        const instr = psx.fetch(self.pc);
        self.pc = self.next_pc;
        self.next_pc = self.pc +% 4;
        self.in_delay = self.branch_taken_prev;
        self.branch_taken = false;

        // load delay: registros escritos por esta instrução vão para `out`
        var out = self.r;
        self.pend_reg = self.ld_reg;
        self.pend_val = self.ld_val;
        self.ld_reg = 0;
        self.last_write = 0;
        self.exec(psx, instr, &out);
        // o load anterior conclui agora (a menos que esta instrução tenha escrito o mesmo reg)
        if (self.pend_reg != 0 and self.pend_reg != self.last_write) out[self.pend_reg] = self.pend_val;
        out[0] = 0;
        self.r = out;
        self.branch_taken_prev = self.branch_taken;
        psx.cycles += 1;
    }


    fn flushLoad(self: *Cpu) void {
        if (self.ld_reg != 0) self.r[self.ld_reg] = self.ld_val;
        self.ld_reg = 0;
        self.r[0] = 0;
    }

    inline fn branch(self: *Cpu, off: u32) void {
        self.next_pc = self.pc +% (off << 2);
        self.branch_taken = true;
    }

    inline fn load(self: *Cpu, out: *[32]u32, rt: u5, v: u32) void {
        _ = out;
        if (self.pend_reg == rt) self.pend_reg = 0;
        self.ld_reg = rt;
        self.ld_val = v;
    }

    fn exec(self: *Cpu, psx: *Psx, i: u32, out: *[32]u32) void {
        const op: u6 = @truncate(i >> 26);
        const rs: u5 = @truncate(i >> 21);
        const rt: u5 = @truncate(i >> 16);
        const rd: u5 = @truncate(i >> 11);
        const sh: u5 = @truncate(i >> 6);
        const imm: u32 = i & 0xFFFF;
        const simm: u32 = @bitCast(@as(i32, @as(i16, @bitCast(@as(u16, @truncate(i))))));
        const r = &self.r;
        switch (op) {
            0x00 => switch (@as(u6, @truncate(i))) {
                0x00 => self.wr(out, rd, r[rt] << sh),
                0x02 => self.wr(out, rd, r[rt] >> sh),
                0x03 => self.wr(out, rd, @bitCast(@as(i32, @bitCast(r[rt])) >> sh)),
                0x04 => self.wr(out, rd, r[rt] << @truncate(r[rs])),
                0x06 => self.wr(out, rd, r[rt] >> @truncate(r[rs])),
                0x07 => self.wr(out, rd, @bitCast(@as(i32, @bitCast(r[rt])) >> @truncate(r[rs]))),
                0x08 => {
                    self.next_pc = r[rs];
                    self.branch_taken = true;
                },
                0x09 => {
                    const t = r[rs];
                    self.wr(out, rd, self.next_pc);
                    self.next_pc = t;
                    self.branch_taken = true;
                },
                0x0C => self.exception(.syscall),
                0x0D => self.exception(.brk),
                0x10 => self.wr(out, rd, self.hi),
                0x11 => self.hi = r[rs],
                0x12 => self.wr(out, rd, self.lo),
                0x13 => self.lo = r[rs],
                0x18 => {
                    const p: i64 = @as(i64, @as(i32, @bitCast(r[rs]))) * @as(i64, @as(i32, @bitCast(r[rt])));
                    const u: u64 = @bitCast(p);
                    self.lo = @truncate(u);
                    self.hi = @truncate(u >> 32);
                    psx.cycles += 6;
                },
                0x19 => {
                    const p: u64 = @as(u64, r[rs]) * @as(u64, r[rt]);
                    self.lo = @truncate(p);
                    self.hi = @truncate(p >> 32);
                    psx.cycles += 6;
                },
                0x1A => {
                    const n: i32 = @bitCast(r[rs]);
                    const d: i32 = @bitCast(r[rt]);
                    if (d == 0) {
                        self.hi = @bitCast(n);
                        self.lo = if (n >= 0) 0xFFFFFFFF else 1;
                    } else if (n == std.math.minInt(i32) and d == -1) {
                        self.hi = 0;
                        self.lo = 0x80000000;
                    } else {
                        self.lo = @bitCast(@divTrunc(n, d));
                        self.hi = @bitCast(@rem(n, d));
                    }
                    psx.cycles += 34;
                },
                0x1B => {
                    const n = r[rs];
                    const d = r[rt];
                    if (d == 0) {
                        self.hi = n;
                        self.lo = 0xFFFFFFFF;
                    } else {
                        self.lo = n / d;
                        self.hi = n % d;
                    }
                    psx.cycles += 34;
                },
                0x20 => {
                    const res = @addWithOverflow(@as(i32, @bitCast(r[rs])), @as(i32, @bitCast(r[rt])));
                    if (res[1] != 0) self.exception(.ov) else self.wr(out, rd, @bitCast(res[0]));
                },
                0x21 => self.wr(out, rd, r[rs] +% r[rt]),
                0x22 => {
                    const res = @subWithOverflow(@as(i32, @bitCast(r[rs])), @as(i32, @bitCast(r[rt])));
                    if (res[1] != 0) self.exception(.ov) else self.wr(out, rd, @bitCast(res[0]));
                },
                0x23 => self.wr(out, rd, r[rs] -% r[rt]),
                0x24 => self.wr(out, rd, r[rs] & r[rt]),
                0x25 => self.wr(out, rd, r[rs] | r[rt]),
                0x26 => self.wr(out, rd, r[rs] ^ r[rt]),
                0x27 => self.wr(out, rd, ~(r[rs] | r[rt])),
                0x2A => self.wr(out, rd, @intFromBool(@as(i32, @bitCast(r[rs])) < @as(i32, @bitCast(r[rt])))),
                0x2B => self.wr(out, rd, @intFromBool(r[rs] < r[rt])),
                else => self.exception(.ri),
            },
            0x01 => {
                const link = (rt & 0x1E) == 0x10;
                const ge = (rt & 1) != 0;
                const v: i32 = @bitCast(r[rs]);
                const taken = if (ge) v >= 0 else v < 0;
                if (link) self.wr(out, 31, self.next_pc);
                if (taken) self.branch(simm);
            },
            0x02 => {
                self.next_pc = (self.pc & 0xF0000000) | ((i & 0x3FFFFFF) << 2);
                self.branch_taken = true;
            },
            0x03 => {
                self.wr(out, 31, self.next_pc);
                self.next_pc = (self.pc & 0xF0000000) | ((i & 0x3FFFFFF) << 2);
                self.branch_taken = true;
            },
            0x04 => if (r[rs] == r[rt]) self.branch(simm),
            0x05 => if (r[rs] != r[rt]) self.branch(simm),
            0x06 => if (@as(i32, @bitCast(r[rs])) <= 0) self.branch(simm),
            0x07 => if (@as(i32, @bitCast(r[rs])) > 0) self.branch(simm),
            0x08 => {
                const res = @addWithOverflow(@as(i32, @bitCast(r[rs])), @as(i32, @bitCast(simm)));
                if (res[1] != 0) self.exception(.ov) else self.wr(out, rt, @bitCast(res[0]));
            },
            0x09 => self.wr(out, rt, r[rs] +% simm),
            0x0A => self.wr(out, rt, @intFromBool(@as(i32, @bitCast(r[rs])) < @as(i32, @bitCast(simm)))),
            0x0B => self.wr(out, rt, @intFromBool(r[rs] < simm)),
            0x0C => self.wr(out, rt, r[rs] & imm),
            0x0D => self.wr(out, rt, r[rs] | imm),
            0x0E => self.wr(out, rt, r[rs] ^ imm),
            0x0F => self.wr(out, rt, imm << 16),
            0x10 => self.cop0(i, rs, rt, rd, out),
            0x12 => self.cop2(psx, i, rs, rt, rd, out),
            0x11, 0x13 => self.exception(.cpu),
            0x20, 0x21, 0x23, 0x24, 0x25, 0x22, 0x26 => {
                const addr = r[rs] +% simm;
                if (self.sr & (1 << 16) != 0 and op != 0x22 and op != 0x26) {
                    // cache isolado: leituras devolvem lixo; ignoramos
                }
                switch (op) {
                    0x20 => self.load(out, rt, @bitCast(@as(i32, @as(i8, @bitCast(psx.read8(addr)))))),
                    0x24 => self.load(out, rt, psx.read8(addr)),
                    0x21, 0x25 => {
                        if (addr & 1 != 0) {
                            self.badv = addr;
                            self.exception(.adel);
                            return;
                        }
                        const h = psx.read16(addr);
                        self.load(out, rt, if (op == 0x21) @bitCast(@as(i32, @as(i16, @bitCast(h)))) else h);
                    },
                    0x23 => {
                        if (addr & 3 != 0) {
                            self.badv = addr;
                            self.exception(.adel);
                            return;
                        }
                        self.load(out, rt, psx.read32(addr));
                    },
                    0x22 => { // LWL: usa o valor pendente do load anterior se for o mesmo reg
                        const cur = if (self.ld_reg_prev(rt)) |v| v else r[rt];
                        const w = psx.read32(addr & ~@as(u32, 3));
                        const v: u32 = switch (@as(u2, @truncate(addr))) {
                            0 => (cur & 0x00FFFFFF) | (w << 24),
                            1 => (cur & 0x0000FFFF) | (w << 16),
                            2 => (cur & 0x000000FF) | (w << 8),
                            3 => w,
                        };
                        self.load(out, rt, v);
                    },
                    0x26 => { // LWR
                        const cur = if (self.ld_reg_prev(rt)) |v| v else r[rt];
                        const w = psx.read32(addr & ~@as(u32, 3));
                        const v: u32 = switch (@as(u2, @truncate(addr))) {
                            0 => w,
                            1 => (cur & 0xFF000000) | (w >> 8),
                            2 => (cur & 0xFFFF0000) | (w >> 16),
                            3 => (cur & 0xFFFFFF00) | (w >> 24),
                        };
                        self.load(out, rt, v);
                    },
                    else => unreachable,
                }
            },
            0x28, 0x29, 0x2B, 0x2A, 0x2E => {
                const addr = r[rs] +% simm;
                if (self.sr & (1 << 16) != 0) return; // cache isolado
                switch (op) {
                    0x28 => psx.write8(addr, @truncate(r[rt])),
                    0x29 => {
                        if (addr & 1 != 0) {
                            self.badv = addr;
                            self.exception(.ades);
                            return;
                        }
                        psx.write16(addr, @truncate(r[rt]));
                    },
                    0x2B => {
                        if (addr & 3 != 0) {
                            self.badv = addr;
                            self.exception(.ades);
                            return;
                        }
                        psx.write32(addr, r[rt]);
                    },
                    0x2A => { // SWL
                        const a = addr & ~@as(u32, 3);
                        const w = psx.read32(a);
                        const v = r[rt];
                        psx.write32(a, switch (@as(u2, @truncate(addr))) {
                            0 => (w & 0xFFFFFF00) | (v >> 24),
                            1 => (w & 0xFFFF0000) | (v >> 16),
                            2 => (w & 0xFF000000) | (v >> 8),
                            3 => v,
                        });
                    },
                    0x2E => { // SWR
                        const a = addr & ~@as(u32, 3);
                        const w = psx.read32(a);
                        const v = r[rt];
                        psx.write32(a, switch (@as(u2, @truncate(addr))) {
                            0 => v,
                            1 => (w & 0x000000FF) | (v << 8),
                            2 => (w & 0x0000FFFF) | (v << 16),
                            3 => (w & 0x00FFFFFF) | (v << 24),
                        });
                    },
                    else => unreachable,
                }
            },
            0x32 => { // LWC2
                const addr = r[rs] +% simm;
                psx.gte.write(rt, psx.read32(addr));
            },
            0x3A => { // SWC2
                const addr = r[rs] +% simm;
                psx.write32(addr, psx.gte.read(rt));
            },
            else => self.exception(.ri),
        }
    }

    // Valor do load ainda pendente para LWL/LWR encadeados.
    fn ld_reg_prev(self: *Cpu, rt: u5) ?u32 {
        return if (self.pend_reg == rt and rt != 0) self.pend_val else null;
    }

    fn cop0(self: *Cpu, i: u32, rs: u5, rt: u5, rd: u5, out: *[32]u32) void {
        switch (rs) {
            0x00 => { // MFC0
                const v: u32 = switch (rd) {
                    8 => self.badv,
                    12 => self.sr,
                    13 => self.cause,
                    14 => self.epc,
                    15 => 0x00000002,
                    else => 0,
                };
                self.load(out, rt, v);
            },
            0x04 => switch (rd) { // MTC0
                12 => self.sr = self.r[rt],
                13 => self.cause = (self.cause & ~@as(u32, 0x300)) | (self.r[rt] & 0x300),
                else => {},
            },
            0x10 => if ((i & 0x3F) == 0x10) { // RFE
                const mode = self.sr & 0x3F;
                self.sr = (self.sr & ~@as(u32, 0xF)) | (mode >> 2);
            },
            else => self.exception(.ri),
        }
    }

    fn cop2(self: *Cpu, psx: *Psx, i: u32, rs: u5, rt: u5, rd: u5, out: *[32]u32) void {
        if (i & (1 << 25) != 0) {
            psx.gte.command(i);
            psx.cycles += 8;
            return;
        }
        switch (rs) {
            0x00 => self.load(out, rt, psx.gte.read(rd)),
            0x02 => self.load(out, rt, psx.gte.read(@as(u6, rd) + 32)),
            0x04 => psx.gte.write(rd, self.r[rt]),
            0x06 => psx.gte.write(@as(u6, rd) + 32, self.r[rt]),
            else => self.exception(.ri),
        }
    }
};
