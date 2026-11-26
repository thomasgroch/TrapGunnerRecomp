//! MDEC: decodificador de macroblocos (FMV/STR). Comandos 1 (decodificar),
//! 2 (tabelas de quantização) e 3 (tabela de escala/IDCT). Entrada via
//! DMA0, saída via DMA1, em 15 ou 24 bits.
const std = @import("std");

const zigzag = [64]u8{
    0,  1,  8,  16, 9,  2,  3,  10, 17, 24, 32, 25, 18, 11, 4,  5,
    12, 19, 26, 33, 40, 48, 41, 34, 27, 20, 13, 6,  7,  14, 21, 28,
    35, 42, 49, 56, 57, 50, 43, 36, 29, 22, 15, 23, 30, 37, 44, 51,
    58, 59, 52, 45, 38, 31, 39, 46, 53, 60, 61, 54, 47, 55, 62, 63,
};

pub const Mdec = struct {
    in_buf: [0x20000]u32 = undefined,
    in_len: u32 = 0,
    in_need: u32 = 0,
    cmd: u32 = 0,
    out: [0x40000]u32 = undefined,
    out_len: u32 = 0,
    out_pos: u32 = 0,
    qt_y: [64]u8 = @splat(1),
    qt_c: [64]u8 = @splat(1),
    scale: [64]i16 = @splat(0),
    enable_in: bool = false,
    enable_out: bool = false,
    dbg_decodes: u32 = 0,
    dbg_words: u64 = 0,
    dbg_lastcmd: u32 = 0,

    pub fn status(self: *Mdec) u32 {
        var s: u32 = 0;
        if (self.out_pos >= self.out_len) s |= 1 << 31;
        if (self.in_need > self.in_len) s |= 1 << 29; // ocupado esperando parâmetros
        if (self.enable_in) s |= 1 << 28;
        if (self.enable_out and self.out_pos < self.out_len) s |= 1 << 27;
        s |= ((self.cmd >> 25) & 0xF) << 23; // depth/signed/bit15
        const rem: u32 = if (self.in_need > self.in_len) self.in_need - self.in_len - 1 else 0xFFFF;
        s |= rem & 0xFFFF;
        return s;
    }

    pub fn control(self: *Mdec, v: u32) void {
        if (v & 0x80000000 != 0) {
            self.in_len = 0;
            self.in_need = 0;
            self.out_len = 0;
            self.out_pos = 0;
            self.cmd = 0;
        }
        self.enable_in = v & (1 << 30) != 0;
        self.enable_out = v & (1 << 29) != 0;
    }

    pub fn readData(self: *Mdec) u32 {
        if (self.out_pos < self.out_len) {
            const w = self.out[self.out_pos];
            self.out_pos += 1;
            return w;
        }
        return 0;
    }

    pub fn writeData(self: *Mdec, v: u32) void {
        if (self.in_need == 0 or self.in_len >= self.in_need) {
            // novo comando
            self.cmd = v;
            self.in_len = 0;
            self.in_need = switch (v >> 29) {
                1 => v & 0xFFFF,
                2 => if (v & 1 != 0) 32 else 16,
                3 => 32,
                else => 0,
            };
            if (self.in_need == 0) return;
            return;
        }
        if (self.in_len < self.in_buf.len) self.in_buf[self.in_len] = v;
        self.in_len += 1;
        if (self.in_len == self.in_need) self.finish();
    }

    fn finish(self: *Mdec) void {
        switch (self.cmd >> 29) {
            1 => self.decode(),
            2 => {
                const b = std.mem.sliceAsBytes(self.in_buf[0..self.in_need]);
                @memcpy(&self.qt_y, b[0..64]);
                if (self.cmd & 1 != 0) @memcpy(&self.qt_c, b[64..128]);
            },
            3 => {
                for (0..32) |i| {
                    const w = self.in_buf[i];
                    self.scale[i * 2] = @bitCast(@as(u16, @truncate(w)));
                    self.scale[i * 2 + 1] = @bitCast(@as(u16, @truncate(w >> 16)));
                }
            },
            else => {},
        }
    }

    // ------- decodificação -------
    fn halfword(self: *Mdec, idx: u32) u16 {
        const w = self.in_buf[idx / 2];
        return @truncate(if (idx & 1 == 0) w else w >> 16);
    }

    fn sext10(v: u16) i32 {
        return @as(i32, @as(i16, @bitCast(v << 6))) >> 6;
    }

    /// Lê um bloco 8x8 RLE; devolve false no fim dos dados.
    fn rlBlock(self: *Mdec, pos: *u32, blk: *[64]i32, qt: *const [64]u8) bool {
        const total = self.in_need * 2;
        // pula padding 0xFE00
        while (pos.* < total and self.halfword(pos.*) == 0xFE00) pos.* += 1;
        if (pos.* >= total) return false;
        @memset(blk, 0);
        var hw = self.halfword(pos.*);
        pos.* += 1;
        const q: i32 = @intCast(hw >> 10);
        var k: u32 = 0;
        var val: i32 = sext10(hw) * qt[0];
        while (true) {
            if (q == 0) val = sext10(hw) * 2;
            val = std.math.clamp(val, -0x400, 0x3FF);
            if (q == 0) blk[k] = val else blk[zigzag[k]] = val;
            if (pos.* >= total) break;
            hw = self.halfword(pos.*);
            pos.* += 1;
            if (hw == 0xFE00) break;
            k += (hw >> 10) + 1;
            if (k > 63) break;
            val = @divTrunc(sext10(hw) * qt[k] * q + 4, 8);
        }
        self.idct(blk);
        return true;
    }

    fn idct(self: *Mdec, blk: *[64]i32) void {
        var tmp: [64]i64 = undefined;
        for (0..8) |x| {
            for (0..8) |y| {
                var s: i64 = 0;
                for (0..8) |z| s += @as(i64, blk[y + z * 8]) * self.scale[x + z * 8];
                tmp[x + y * 8] = s;
            }
        }
        for (0..8) |x| {
            for (0..8) |y| {
                var s: i64 = 0;
                for (0..8) |z| s += tmp[y + z * 8] * self.scale[x + z * 8];
                // (s >> 32) com arredondamento: escala 2x 0x5A82 ~ (2^15)
                blk[x + y * 8] = @intCast(std.math.clamp((s + (1 << 31)) >> 32, -128, 127));
            }
        }
    }

    fn decode(self: *Mdec) void {
        self.dbg_decodes += 1;
        self.dbg_lastcmd = self.cmd;
        defer self.dbg_words += self.out_len;
        const depth = (self.cmd >> 27) & 3;
        const signed = self.cmd & (1 << 26) != 0;
        const bit15: u32 = if (self.cmd & (1 << 25) != 0) 0x8000 else 0;
        self.out_len = 0;
        self.out_pos = 0;
        var pos: u32 = 0;
        var cr: [64]i32 = undefined;
        var cb: [64]i32 = undefined;
        var y: [4][64]i32 = undefined;
        if (depth < 2) return; // 4/8 bits (monocromático) não usados aqui
        while (true) {
            if (!self.rlBlock(&pos, &cr, &self.qt_c)) break;
            if (!self.rlBlock(&pos, &cb, &self.qt_c)) break;
            var ok = true;
            for (0..4) |i| {
                if (!self.rlBlock(&pos, &y[i], &self.qt_y)) {
                    ok = false;
                    break;
                }
            }
            if (!ok) break;
            // monta 16x16 RGB
            var px: [256][3]u8 = undefined;
            for (0..16) |yy| {
                for (0..16) |xx| {
                    const bi = (yy / 8) * 2 + (xx / 8);
                    const lum = y[bi][(yy % 8) * 8 + (xx % 8)];
                    const ci = (yy / 2) * 8 + (xx / 2);
                    const R = cr[ci];
                    const B = cb[ci];
                    const G = @divTrunc(-22524 * B - 46819 * R, 65536);
                    var rgb = [3]i32{
                        lum + @divTrunc(91881 * R, 65536),
                        lum + G,
                        lum + @divTrunc(116130 * B, 65536),
                    };
                    for (&rgb) |*c| {
                        c.* = std.math.clamp(c.*, -128, 127);
                        if (!signed) c.* += 128;
                    }
                    px[yy * 16 + xx] = .{ @intCast(rgb[0] & 0xFF), @intCast(rgb[1] & 0xFF), @intCast(rgb[2] & 0xFF) };
                }
            }
            if (depth == 3) { // 15 bits
                var i: usize = 0;
                while (i < 256) : (i += 2) {
                    var w: u32 = 0;
                    for (0..2) |k| {
                        const p = px[i + k];
                        const v: u32 = (@as(u32, p[0]) >> 3) | ((@as(u32, p[1]) >> 3) << 5) | ((@as(u32, p[2]) >> 3) << 10) | bit15;
                        w |= v << @intCast(k * 16);
                    }
                    self.push(w);
                }
            } else { // 24 bits: 3 bytes por pixel empacotados
                var bytes: [768]u8 = undefined;
                for (0..256) |i| {
                    bytes[i * 3] = px[i][0];
                    bytes[i * 3 + 1] = px[i][1];
                    bytes[i * 3 + 2] = px[i][2];
                }
                var i: usize = 0;
                while (i < 768) : (i += 4) self.push(std.mem.readInt(u32, bytes[i..][0..4], .little));
            }
        }
    }

    fn push(self: *Mdec, w: u32) void {
        if (self.out_len < self.out.len) {
            self.out[self.out_len] = w;
            self.out_len += 1;
        }
    }
};
