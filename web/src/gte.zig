//! GTE (COP2): transformação, projeção perspectiva e iluminação em ponto fixo.
//! Escrito a partir da documentação pública de hardware (registradores 0-63,
//! flags de saturação, divisão por Newton-Raphson com tabela UNR).
const std = @import("std");

pub const Gte = struct {
    // dados
    v: [3][3]i16 = @splat(@splat(0)), // V0..V2 (x,y,z)
    rgbc: [4]u8 = @splat(0),
    otz: u16 = 0,
    ir: [4]i16 = @splat(0),
    sxy: [3][2]i16 = @splat(@splat(0)),
    sz: [4]u16 = @splat(0),
    rgb: [3][4]u8 = @splat(@splat(0)),
    res1: u32 = 0,
    mac: [4]i32 = @splat(0),
    lzcs: u32 = 0,
    lzcr: u32 = 32,
    // controle
    rt: [3][3]i16 = @splat(@splat(0)),
    tr: [3]i32 = @splat(0),
    llm: [3][3]i16 = @splat(@splat(0)),
    bk: [3]i32 = @splat(0),
    lcm: [3][3]i16 = @splat(@splat(0)),
    fc: [3]i32 = @splat(0),
    ofx: i32 = 0,
    ofy: i32 = 0,
    h: u16 = 0,
    dqa: i16 = 0,
    dqb: i32 = 0,
    zsf3: i16 = 0,
    zsf4: i16 = 0,
    flag: u32 = 0,

    // ---------- acesso a registradores ----------
    pub fn read(self: *Gte, reg: u6) u32 {
        return switch (reg) {
            0 => pack16(self.v[0][0], self.v[0][1]),
            1 => sx(self.v[0][2]),
            2 => pack16(self.v[1][0], self.v[1][1]),
            3 => sx(self.v[1][2]),
            4 => pack16(self.v[2][0], self.v[2][1]),
            5 => sx(self.v[2][2]),
            6 => std.mem.readInt(u32, &self.rgbc, .little),
            7 => self.otz,
            8...11 => sx(self.ir[reg - 8]),
            12...14 => pack16(self.sxy[reg - 12][0], self.sxy[reg - 12][1]),
            15 => pack16(self.sxy[2][0], self.sxy[2][1]),
            16...19 => self.sz[reg - 16],
            20...22 => std.mem.readInt(u32, &self.rgb[reg - 20], .little),
            23 => self.res1,
            24...27 => @bitCast(self.mac[reg - 24]),
            28, 29 => blk: {
                const r: u32 = @intCast(std.math.clamp(@as(i32, self.ir[1]) >> 7, 0, 0x1F));
                const g: u32 = @intCast(std.math.clamp(@as(i32, self.ir[2]) >> 7, 0, 0x1F));
                const b: u32 = @intCast(std.math.clamp(@as(i32, self.ir[3]) >> 7, 0, 0x1F));
                break :blk r | (g << 5) | (b << 10);
            },
            30 => self.lzcs,
            31 => self.lzcr,
            32 => pack16(self.rt[0][0], self.rt[0][1]),
            33 => pack16(self.rt[0][2], self.rt[1][0]),
            34 => pack16(self.rt[1][1], self.rt[1][2]),
            35 => pack16(self.rt[2][0], self.rt[2][1]),
            36 => sx(self.rt[2][2]),
            37...39 => @bitCast(self.tr[reg - 37]),
            40 => pack16(self.llm[0][0], self.llm[0][1]),
            41 => pack16(self.llm[0][2], self.llm[1][0]),
            42 => pack16(self.llm[1][1], self.llm[1][2]),
            43 => pack16(self.llm[2][0], self.llm[2][1]),
            44 => sx(self.llm[2][2]),
            45...47 => @bitCast(self.bk[reg - 45]),
            48 => pack16(self.lcm[0][0], self.lcm[0][1]),
            49 => pack16(self.lcm[0][2], self.lcm[1][0]),
            50 => pack16(self.lcm[1][1], self.lcm[1][2]),
            51 => pack16(self.lcm[2][0], self.lcm[2][1]),
            52 => sx(self.lcm[2][2]),
            53...55 => @bitCast(self.fc[reg - 53]),
            56 => @bitCast(self.ofx),
            57 => @bitCast(self.ofy),
            58 => sx(@bitCast(self.h)), // lido com extensão de sinal (bug de hardware)
            59 => sx(self.dqa),
            60 => @bitCast(self.dqb),
            61 => sx(self.zsf3),
            62 => sx(self.zsf4),
            63 => blk: {
                var f = self.flag & 0x7FFFF000;
                if (f & 0x7F87E000 != 0) f |= 0x80000000;
                break :blk f;
            },
        };
    }

    pub fn write(self: *Gte, reg: u6, val: u32) void {
        const lo: i16 = @bitCast(@as(u16, @truncate(val)));
        const hi: i16 = @bitCast(@as(u16, @truncate(val >> 16)));
        switch (reg) {
            0 => {
                self.v[0][0] = lo;
                self.v[0][1] = hi;
            },
            1 => self.v[0][2] = lo,
            2 => {
                self.v[1][0] = lo;
                self.v[1][1] = hi;
            },
            3 => self.v[1][2] = lo,
            4 => {
                self.v[2][0] = lo;
                self.v[2][1] = hi;
            },
            5 => self.v[2][2] = lo,
            6 => std.mem.writeInt(u32, &self.rgbc, val, .little),
            7 => self.otz = @truncate(val),
            8...11 => self.ir[reg - 8] = lo,
            12...14 => self.sxy[reg - 12] = .{ lo, hi },
            15 => { // SXYP: empurra a FIFO
                self.sxy[0] = self.sxy[1];
                self.sxy[1] = self.sxy[2];
                self.sxy[2] = .{ lo, hi };
            },
            16...19 => self.sz[reg - 16] = @truncate(val),
            20...22 => std.mem.writeInt(u32, &self.rgb[reg - 20], val, .little),
            23 => self.res1 = val,
            24...27 => self.mac[reg - 24] = @bitCast(val),
            28 => {
                self.ir[1] = @intCast((val & 0x1F) << 7);
                self.ir[2] = @intCast(((val >> 5) & 0x1F) << 7);
                self.ir[3] = @intCast(((val >> 10) & 0x1F) << 7);
            },
            29 => {},
            30 => {
                self.lzcs = val;
                const s: i32 = @bitCast(val);
                self.lzcr = if (s >= 0) @clz(val) else @clz(~val);
            },
            31 => {},
            32 => {
                self.rt[0][0] = lo;
                self.rt[0][1] = hi;
            },
            33 => {
                self.rt[0][2] = lo;
                self.rt[1][0] = hi;
            },
            34 => {
                self.rt[1][1] = lo;
                self.rt[1][2] = hi;
            },
            35 => {
                self.rt[2][0] = lo;
                self.rt[2][1] = hi;
            },
            36 => self.rt[2][2] = lo,
            37...39 => self.tr[reg - 37] = @bitCast(val),
            40 => {
                self.llm[0][0] = lo;
                self.llm[0][1] = hi;
            },
            41 => {
                self.llm[0][2] = lo;
                self.llm[1][0] = hi;
            },
            42 => {
                self.llm[1][1] = lo;
                self.llm[1][2] = hi;
            },
            43 => {
                self.llm[2][0] = lo;
                self.llm[2][1] = hi;
            },
            44 => self.llm[2][2] = lo,
            45...47 => self.bk[reg - 45] = @bitCast(val),
            48 => {
                self.lcm[0][0] = lo;
                self.lcm[0][1] = hi;
            },
            49 => {
                self.lcm[0][2] = lo;
                self.lcm[1][0] = hi;
            },
            50 => {
                self.lcm[1][1] = lo;
                self.lcm[1][2] = hi;
            },
            51 => {
                self.lcm[2][0] = lo;
                self.lcm[2][1] = hi;
            },
            52 => self.lcm[2][2] = lo,
            53...55 => self.fc[reg - 53] = @bitCast(val),
            56 => self.ofx = @bitCast(val),
            57 => self.ofy = @bitCast(val),
            58 => self.h = @truncate(val),
            59 => self.dqa = lo,
            60 => self.dqb = @bitCast(val),
            61 => self.zsf3 = lo,
            62 => self.zsf4 = lo,
            63 => self.flag = val & 0x7FFFF000,
        }
    }

    fn pack16(a: i16, b: i16) u32 {
        return @as(u32, @as(u16, @bitCast(a))) | (@as(u32, @as(u16, @bitCast(b))) << 16);
    }
    fn sx(a: i16) u32 {
        return @bitCast(@as(i32, a));
    }

    // ---------- helpers de saturação ----------
    fn macCheck(self: *Gte, i: usize, v: i64) i64 {
        if (v > 0x7FFFFFFFFFF) self.flag |= @as(u32, 1) << @intCast(31 - i);
        if (v < -0x80000000000) self.flag |= @as(u32, 1) << @intCast(28 - i);
        // simula overflow de 44 bits
        return (v << 20) >> 20;
    }
    fn setMac(self: *Gte, i: usize, v: i64, sf: u5) i32 {
        const c = self.macCheck(i, v);
        const r: i32 = @truncate(c >> sf);
        self.mac[i] = r;
        return r;
    }
    fn setIr(self: *Gte, i: usize, v: i32, lm: bool) void {
        const lo: i32 = if (lm) 0 else -0x8000;
        if (v > 0x7FFF) {
            self.ir[i] = 0x7FFF;
            self.flag |= @as(u32, 1) << @intCast(25 - i);
        } else if (v < lo) {
            self.ir[i] = @intCast(lo);
            self.flag |= @as(u32, 1) << @intCast(25 - i);
        } else self.ir[i] = @intCast(v);
    }
    fn mac0(self: *Gte, v: i64) i32 {
        if (v > 0x7FFFFFFF) self.flag |= 1 << 16;
        if (v < -0x80000000) self.flag |= 1 << 15;
        const r: i32 = @truncate(v);
        self.mac[0] = r;
        return r;
    }
    fn pushSz(self: *Gte, v: i64) void {
        self.sz[0] = self.sz[1];
        self.sz[1] = self.sz[2];
        self.sz[2] = self.sz[3];
        var z = v;
        if (z > 0xFFFF) {
            z = 0xFFFF;
            self.flag |= 1 << 18;
        } else if (z < 0) {
            z = 0;
            self.flag |= 1 << 18;
        }
        self.sz[3] = @intCast(z);
    }
    fn pushSxy(self: *Gte, x: i64, y: i64) void {
        self.sxy[0] = self.sxy[1];
        self.sxy[1] = self.sxy[2];
        self.sxy[2] = .{ self.sat11(x, 14), self.sat11(y, 13) };
    }
    fn sat11(self: *Gte, v: i64, bit: u5) i16 {
        if (v > 0x3FF) {
            self.flag |= @as(u32, 1) << bit;
            return 0x3FF;
        }
        if (v < -0x400) {
            self.flag |= @as(u32, 1) << bit;
            return -0x400;
        }
        return @intCast(v);
    }
    fn colorSat(self: *Gte, v: i32, bit: u5) u8 {
        if (v < 0) {
            self.flag |= @as(u32, 1) << bit;
            return 0;
        }
        if (v > 0xFF) {
            self.flag |= @as(u32, 1) << bit;
            return 0xFF;
        }
        return @intCast(v);
    }
    fn pushColor(self: *Gte) void {
        self.rgb[0] = self.rgb[1];
        self.rgb[1] = self.rgb[2];
        self.rgb[2] = .{
            self.colorSat(self.mac[1] >> 4, 21),
            self.colorSat(self.mac[2] >> 4, 20),
            self.colorSat(self.mac[3] >> 4, 19),
            self.rgbc[3],
        };
    }

    fn unr(i: u32) u32 {
        const v: i32 = @divTrunc(@divTrunc(@as(i32, 0x40000), @as(i32, @intCast(i + 0x100))) + 1, 2) - 0x101;
        return @intCast(@max(0, v));
    }

    fn divide(self: *Gte) u32 {
        const hh: u32 = self.h;
        const sz3: u32 = self.sz[3];
        if (hh >= sz3 * 2) {
            self.flag |= 1 << 17;
            return 0x1FFFF;
        }
        const z: u5 = @intCast(@clz(@as(u16, @truncate(sz3))));
        const n: u64 = @as(u64, hh) << z;
        var d: u32 = sz3 << z;
        const u: u32 = unr((d - 0x7FC0) >> 7) + 0x101;
        d = @truncate((0x2000080 - @as(u64, d) * u) >> 8);
        d = @truncate((0x0000080 + @as(u64, d) * u) >> 8);
        const r: u64 = (n * d + 0x8000) >> 16;
        return @intCast(@min(0x1FFFF, r));
    }

    // ---------- comandos ----------
    pub fn command(self: *Gte, cmd: u32) void {
        self.flag = 0;
        const sf: u5 = if (cmd & (1 << 19) != 0) 12 else 0;
        const lm = cmd & (1 << 10) != 0;
        switch (cmd & 0x3F) {
            0x01 => self.rtp(0, sf, lm, true),
            0x06 => { // NCLIP
                const s = self.sxy;
                const v: i64 = @as(i64, s[0][0]) * s[1][1] + @as(i64, s[1][0]) * s[2][1] + @as(i64, s[2][0]) * s[0][1] -
                    @as(i64, s[0][0]) * s[2][1] - @as(i64, s[1][0]) * s[0][1] - @as(i64, s[2][0]) * s[1][1];
                _ = self.mac0(v);
            },
            0x0C => { // OP
                const d = [3]i64{ self.rt[0][0], self.rt[1][1], self.rt[2][2] };
                const ir = [4]i64{ 0, self.ir[1], self.ir[2], self.ir[3] };
                const m1 = self.setMac(1, ir[3] * d[1] - ir[2] * d[2], sf);
                const m2 = self.setMac(2, ir[1] * d[2] - ir[3] * d[0], sf);
                const m3 = self.setMac(3, ir[2] * d[0] - ir[1] * d[1], sf);
                self.setIr(1, m1, lm);
                self.setIr(2, m2, lm);
                self.setIr(3, m3, lm);
            },
            0x10 => self.dpc(sf, lm, self.rgbc, false), // DPCS
            0x11 => { // INTPL
                const ir = [3]i64{ self.ir[1], self.ir[2], self.ir[3] };
                self.interp(.{ ir[0] << 12, ir[1] << 12, ir[2] << 12 }, sf, lm);
                self.pushColor();
            },
            0x12 => self.mvmva(cmd, sf, lm),
            0x13 => self.ncd(0, sf, lm),
            0x14 => self.cdp(sf, lm),
            0x16 => for (0..3) |i| self.ncd(i, sf, lm),
            0x1B => self.ncc(0, sf, lm),
            0x1C => self.cc(sf, lm),
            0x1E => self.nc(0, sf, lm),
            0x20 => for (0..3) |i| self.nc(i, sf, lm),
            0x28 => { // SQR
                for (1..4) |i| {
                    const ir: i64 = self.ir[i];
                    const m = self.setMac(i, ir * ir, sf);
                    self.setIr(i, m, lm);
                }
            },
            0x29 => { // DCPL
                const c = self.rgbc;
                const ir = [3]i64{ self.ir[1], self.ir[2], self.ir[3] };
                self.interp(.{ (@as(i64, c[0]) * ir[0]) << 4, (@as(i64, c[1]) * ir[1]) << 4, (@as(i64, c[2]) * ir[2]) << 4 }, sf, lm);
                self.pushColor();
            },
            0x2A => for (0..3) |_| self.dpc(sf, lm, self.rgb[0], true), // DPCT
            0x2D => { // AVSZ3
                const s: i64 = @as(i64, self.sz[1]) + self.sz[2] + self.sz[3];
                const m = self.mac0(@as(i64, self.zsf3) * s);
                self.otz = self.satOtz(m >> 12);
            },
            0x2E => { // AVSZ4
                const s: i64 = @as(i64, self.sz[0]) + self.sz[1] + self.sz[2] + self.sz[3];
                const m = self.mac0(@as(i64, self.zsf4) * s);
                self.otz = self.satOtz(m >> 12);
            },
            0x30 => for (0..3) |i| self.rtp(i, sf, lm, i == 2), // RTPT
            0x3D => { // GPF
                for (1..4) |i| {
                    const m = self.setMac(i, @as(i64, self.ir[0]) * self.ir[i], sf);
                    self.setIr(i, m, lm);
                }
                self.pushColor();
            },
            0x3E => { // GPL
                for (1..4) |i| {
                    const base: i64 = @as(i64, self.mac[i]) << sf;
                    const m = self.setMac(i, base + @as(i64, self.ir[0]) * self.ir[i], sf);
                    self.setIr(i, m, lm);
                }
                self.pushColor();
            },
            0x3F => for (0..3) |i| self.ncc(i, sf, lm), // NCCT
            else => {},
        }
    }

    fn satOtz(self: *Gte, v: i32) u16 {
        if (v < 0) {
            self.flag |= 1 << 18;
            return 0;
        }
        if (v > 0xFFFF) {
            self.flag |= 1 << 18;
            return 0xFFFF;
        }
        return @intCast(v);
    }

    fn rtp(self: *Gte, n: usize, sf: u5, lm: bool, last: bool) void {
        const v = self.v[n];
        var m: [4]i32 = undefined;
        for (0..3) |i| {
            const sum: i64 = (@as(i64, self.tr[i]) << 12) + @as(i64, self.rt[i][0]) * v[0] + @as(i64, self.rt[i][1]) * v[1] + @as(i64, self.rt[i][2]) * v[2];
            m[i + 1] = self.setMac(i + 1, sum, sf);
        }
        self.setIr(1, m[1], lm);
        self.setIr(2, m[2], lm);
        // IR3: flag de saturação usa o valor de MAC3>>12 (quirk), valor usa lm
        const z12: i32 = @truncate(@as(i64, self.macRaw(3, sf)) >> (12 - @as(u5, sf)));
        _ = z12;
        self.setIr(3, m[3], lm);
        self.pushSz(@as(i64, self.mac[3]) >> @intCast(12 - sf));
        const d: i64 = self.divide();
        const sxv = d * self.ir[1] + self.ofx;
        const syv = d * self.ir[2] + self.ofy;
        _ = self.mac0(sxv);
        _ = self.mac0(syv);
        self.pushSxy(sxv >> 16, syv >> 16);
        if (last) {
            const dq = d * self.dqa + self.dqb;
            const m0 = self.mac0(dq);
            const ir0 = m0 >> 12;
            if (ir0 < 0) {
                self.ir[0] = 0;
                self.flag |= 1 << 12;
            } else if (ir0 > 0x1000) {
                self.ir[0] = 0x1000;
                self.flag |= 1 << 12;
            } else self.ir[0] = @intCast(ir0);
        }
    }

    fn macRaw(self: *Gte, i: usize, sf: u5) i32 {
        return self.mac[i] << sf;
    }

    fn interp(self: *Gte, base: [3]i64, sf: u5, lm: bool) void {
        // MAC = base + (FC<<12 - base) * IR0
        for (0..3) |i| {
            const diff = self.setMac(i + 1, (@as(i64, self.fc[i]) << 12) - base[i], sf);
            self.setIr(i + 1, diff, false);
        }
        for (0..3) |i| {
            const m = self.setMac(i + 1, base[i] + @as(i64, self.ir[i + 1]) * self.ir[0], sf);
            self.setIr(i + 1, m, lm);
        }
    }

    fn dpc(self: *Gte, sf: u5, lm: bool, c: [4]u8, _: bool) void {
        self.interp(.{ @as(i64, c[0]) << 16, @as(i64, c[1]) << 16, @as(i64, c[2]) << 16 }, sf, lm);
        self.pushColor();
    }

    fn mulMat(self: *Gte, mat: [3][3]i16, vec: [3]i64, add: [3]i64, sf: u5, lm: bool) void {
        for (0..3) |i| {
            const s: i64 = add[i] + @as(i64, mat[i][0]) * vec[0] + @as(i64, mat[i][1]) * vec[1] + @as(i64, mat[i][2]) * vec[2];
            const m = self.setMac(i + 1, s, sf);
            self.setIr(i + 1, m, lm);
        }
    }

    fn lightNormal(self: *Gte, n: usize, sf: u5, lm: bool) void {
        const v = self.v[n];
        self.mulMat(self.llm, .{ v[0], v[1], v[2] }, .{ 0, 0, 0 }, sf, lm);
        const ir = [3]i64{ self.ir[1], self.ir[2], self.ir[3] };
        self.mulMat(self.lcm, ir, .{ @as(i64, self.bk[0]) << 12, @as(i64, self.bk[1]) << 12, @as(i64, self.bk[2]) << 12 }, sf, lm);
    }

    fn nc(self: *Gte, n: usize, sf: u5, lm: bool) void {
        self.lightNormal(n, sf, lm);
        self.pushColor();
    }

    fn ncc(self: *Gte, n: usize, sf: u5, lm: bool) void {
        self.lightNormal(n, sf, lm);
        self.colorMul(sf, lm);
        self.pushColor();
    }

    fn colorMul(self: *Gte, sf: u5, lm: bool) void {
        const c = self.rgbc;
        for (0..3) |i| {
            const m = self.setMac(i + 1, (@as(i64, c[i]) * self.ir[i + 1]) << 4, sf);
            self.setIr(i + 1, m, lm);
        }
    }

    fn ncd(self: *Gte, n: usize, sf: u5, lm: bool) void {
        self.lightNormal(n, sf, lm);
        const c = self.rgbc;
        const ir = [3]i64{ self.ir[1], self.ir[2], self.ir[3] };
        self.interp(.{ (@as(i64, c[0]) * ir[0]) << 4, (@as(i64, c[1]) * ir[1]) << 4, (@as(i64, c[2]) * ir[2]) << 4 }, sf, lm);
        self.pushColor();
    }

    fn cc(self: *Gte, sf: u5, lm: bool) void {
        const ir = [3]i64{ self.ir[1], self.ir[2], self.ir[3] };
        self.mulMat(self.lcm, ir, .{ @as(i64, self.bk[0]) << 12, @as(i64, self.bk[1]) << 12, @as(i64, self.bk[2]) << 12 }, sf, lm);
        self.colorMul(sf, lm);
        self.pushColor();
    }

    fn cdp(self: *Gte, sf: u5, lm: bool) void {
        const ir = [3]i64{ self.ir[1], self.ir[2], self.ir[3] };
        self.mulMat(self.lcm, ir, .{ @as(i64, self.bk[0]) << 12, @as(i64, self.bk[1]) << 12, @as(i64, self.bk[2]) << 12 }, sf, lm);
        const c = self.rgbc;
        const ir2 = [3]i64{ self.ir[1], self.ir[2], self.ir[3] };
        self.interp(.{ (@as(i64, c[0]) * ir2[0]) << 4, (@as(i64, c[1]) * ir2[1]) << 4, (@as(i64, c[2]) * ir2[2]) << 4 }, sf, lm);
        self.pushColor();
    }

    fn mvmva(self: *Gte, cmd: u32, sf: u5, lm: bool) void {
        const mx = (cmd >> 17) & 3;
        const vx = (cmd >> 15) & 3;
        const tx = (cmd >> 13) & 3;
        const mat: [3][3]i16 = switch (mx) {
            0 => self.rt,
            1 => self.llm,
            2 => self.lcm,
            else => .{ .{ -@as(i16, @intCast(self.rgbc[0])) << 4, @as(i16, @intCast(self.rgbc[0])) << 4, self.ir[0] }, .{ self.rt[0][2], self.rt[0][2], self.rt[0][2] }, .{ self.rt[1][1], self.rt[1][1], self.rt[1][1] } },
        };
        const vec: [3]i64 = switch (vx) {
            0, 1, 2 => .{ self.v[vx][0], self.v[vx][1], self.v[vx][2] },
            else => .{ self.ir[1], self.ir[2], self.ir[3] },
        };
        const t: [3]i64 = switch (tx) {
            0 => .{ @as(i64, self.tr[0]) << 12, @as(i64, self.tr[1]) << 12, @as(i64, self.tr[2]) << 12 },
            1 => .{ @as(i64, self.bk[0]) << 12, @as(i64, self.bk[1]) << 12, @as(i64, self.bk[2]) << 12 },
            2 => .{ @as(i64, self.fc[0]) << 12, @as(i64, self.fc[1]) << 12, @as(i64, self.fc[2]) << 12 }, // (bug de hardware ignorado)
            else => .{ 0, 0, 0 },
        };
        self.mulMat(mat, vec, t, sf, lm);
    }
};
