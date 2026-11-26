//! GPU do PS1: VRAM 1024x512 (15 bits), GP0/GP1 e rasterizador por software.
const std = @import("std");
const Psx = @import("psx.zig").Psx;

const W = 1024;
const H = 512;

const Vtx = struct { x: i32, y: i32, r: i32 = 0, g: i32 = 0, b: i32 = 0, u: i32 = 0, v: i32 = 0 };

pub const Gpu = struct {
    vram: [W * H]u16 = undefined,

    // FIFO de comando
    cmd: [16]u32 = @splat(0),
    cmd_len: u32 = 0,
    cmd_need: u32 = 0,
    // transferência CPU->VRAM / VRAM->CPU
    xfer_x: u32 = 0,
    xfer_y: u32 = 0,
    xfer_w: u32 = 0,
    xfer_h: u32 = 0,
    xfer_i: u32 = 0,
    xfer_left: u32 = 0,
    xfer_in: bool = false,
    read_left: u32 = 0,
    read_latch: u32 = 0,
    // polilinha
    poly_line: bool = false,
    // estado de desenho
    texpage: u32 = 0,
    tex_win: u32 = 0,
    da_x1: i32 = 0,
    da_y1: i32 = 0,
    da_x2: i32 = 0,
    da_y2: i32 = 0,
    off_x: i32 = 0,
    off_y: i32 = 0,
    mask_set: bool = false,
    mask_check: bool = false,
    // display
    disp_x: u32 = 0,
    disp_y: u32 = 0,
    disp_mode: u32 = 0,
    disp_on: bool = false,
    hrange1: u32 = 0x200,
    hrange2: u32 = 0xC00,
    vrange1: u32 = 0x10,
    vrange2: u32 = 0x100,
    dma_dir: u32 = 0,
    info: u32 = 0,
    dbg_ops: [256]u32 = @splat(0),
    dbg_cp: [8][3]u32 = undefined,
    dbg_cp_n: u32 = 0,

    pub fn reset(self: *Gpu) void {
        const v = self.vram;
        _ = v;
        @memset(&self.vram, 0);
        self.texpage = 0;
        self.cmd_len = 0;
        self.cmd_need = 0;
        self.xfer_in = false;
        self.disp_on = false;
    }

    pub fn status(self: *Gpu, frame: u64) u32 {
        var s: u32 = self.texpage & 0x7FF;
        if (self.mask_set) s |= 1 << 11;
        if (self.mask_check) s |= 1 << 12;
        s |= 1 << 13;
        s |= (self.disp_mode & 0x3F) << 17;
        s |= ((self.disp_mode >> 6) & 1) << 16;
        if (!self.disp_on) s |= 1 << 23;
        s |= self.dma_dir << 29;
        s |= 0x1C000000; // pronto p/ comando, VRAM->CPU e DMA
        if (frame & 1 != 0 and (self.disp_mode & 0x20) != 0) s |= 1 << 31;
        // bit 25: pedido de DMA conforme direção
        switch (self.dma_dir) {
            1 => s |= 1 << 25,
            2 => s |= 1 << 25,
            3 => s |= 1 << 25,
            else => {},
        }
        return s;
    }

    pub fn gpuread(self: *Gpu) u32 {
        if (self.read_left > 0) {
            var out: u32 = 0;
            for (0..2) |k| {
                const px = self.vram[((self.xfer_y + self.xfer_i / self.xfer_w) & 511) * W + ((self.xfer_x + self.xfer_i % self.xfer_w) & 1023)];
                out |= @as(u32, px) << @intCast(k * 16);
                self.xfer_i += 1;
            }
            self.read_left -= 1;
            self.read_latch = out;
            return out;
        }
        return self.info;
    }

    pub fn gp1(self: *Gpu, v: u32) void {
        switch (v >> 24) {
            0x00 => {
                self.cmd_len = 0;
                self.cmd_need = 0;
                self.xfer_in = false;
                self.disp_on = false;
                self.dma_dir = 0;
                self.texpage = 0;
                self.disp_mode = 0;
            },
            0x01 => {
                self.cmd_len = 0;
                self.cmd_need = 0;
                self.xfer_in = false;
            },
            0x02 => {},
            0x03 => self.disp_on = (v & 1) == 0,
            0x04 => self.dma_dir = v & 3,
            0x05 => {
                self.disp_x = v & 0x3FE;
                self.disp_y = (v >> 10) & 0x1FF;
            },
            0x06 => {
                self.hrange1 = v & 0xFFF;
                self.hrange2 = (v >> 12) & 0xFFF;
            },
            0x07 => {
                self.vrange1 = v & 0x3FF;
                self.vrange2 = (v >> 10) & 0x3FF;
            },
            0x08 => self.disp_mode = v & 0xFF,
            0x10...0x1F => self.info = switch (v & 7) {
                2 => self.tex_win,
                3 => @as(u32, @intCast(self.da_x1 & 0x3FF)) | (@as(u32, @intCast(self.da_y1 & 0x3FF)) << 10),
                4 => @as(u32, @intCast(self.da_x2 & 0x3FF)) | (@as(u32, @intCast(self.da_y2 & 0x3FF)) << 10),
                5 => @as(u32, @bitCast(self.off_x & 0x7FF)) | (@as(u32, @bitCast(self.off_y & 0x7FF)) << 11),
                7 => 2,
                else => self.info,
            },
            else => {},
        }
    }

    /// Largura/altura visíveis (para o host desenhar o framebuffer).
    pub fn displaySize(self: *Gpu) struct { w: u32, h: u32 } {
        const hr = self.disp_mode & 3;
        var w: u32 = switch (hr) {
            0 => 256,
            1 => 320,
            2 => 512,
            else => 640,
        };
        if (self.disp_mode & 0x40 != 0) w = 368;
        const h: u32 = if (self.disp_mode & 0x04 != 0 and self.disp_mode & 0x20 != 0) 480 else 240;
        return .{ .w = w, .h = h };
    }

    /// Converte a área visível para RGBA8888 (15 ou 24 bits). Retorna w,h.
    pub fn renderDisplay(self: *Gpu, out: []u8) struct { w: u32, h: u32 } {
        const sz = self.displaySize();
        const w = sz.w;
        const h = @min(sz.h, 480);
        const bpp24 = self.disp_mode & 0x10 != 0;
        var y: u32 = 0;
        while (y < h) : (y += 1) {
            const vy = (self.disp_y + y) & 511;
            var x: u32 = 0;
            while (x < w) : (x += 1) {
                const o = (y * w + x) * 4;
                if (o + 4 > out.len) return .{ .w = w, .h = h };
                var r: u8 = 0;
                var g: u8 = 0;
                var b: u8 = 0;
                if (bpp24) {
                    const byte_x = self.disp_x * 2 + x * 3;
                    const row = vy * W;
                    const B = struct {
                        fn at(v: []const u16, rw: u32, bx: u32) u8 {
                            const px = v[rw + ((bx / 2) & 1023)];
                            return @truncate(if (bx & 1 == 0) px else px >> 8);
                        }
                    };
                    r = B.at(&self.vram, row, byte_x);
                    g = B.at(&self.vram, row, byte_x + 1);
                    b = B.at(&self.vram, row, byte_x + 2);
                } else {
                    const px = self.vram[vy * W + ((self.disp_x + x) & 1023)];
                    r = @intCast((px & 0x1F) << 3);
                    g = @intCast(((px >> 5) & 0x1F) << 3);
                    b = @intCast(((px >> 10) & 0x1F) << 3);
                }
                out[o] = r;
                out[o + 1] = g;
                out[o + 2] = b;
                out[o + 3] = 255;
            }
        }
        return .{ .w = w, .h = h };
    }

    fn cmdLen(op: u8) u32 {
        return switch (op) {
            0x02 => 3,
            0x20...0x3F => blk: {
                const quad = op & 0x08 != 0;
                const tex = op & 0x04 != 0;
                const shaded = op & 0x10 != 0;
                const nv: u32 = if (quad) 4 else 3;
                var n: u32 = 1 + nv; // cor + vértices
                if (tex) n += nv;
                if (shaded) n += nv - 1;
                break :blk n;
            },
            0x40...0x5F => if (op & 0x08 != 0) 0xFF else (if (op & 0x10 != 0) 4 else 3),
            0x60...0x7F => blk: {
                var n: u32 = 2;
                if (op & 0x04 != 0) n += 1;
                if ((op >> 3) & 3 == 0) n += 1;
                break :blk n;
            },
            0x80...0x9F => 4,
            0xA0...0xBF => 3,
            0xC0...0xDF => 3,
            else => 1,
        };
    }

    pub fn gp0(self: *Gpu, v: u32, psx: *Psx) void {
        _ = psx;
        if (self.xfer_in) {
            for (0..2) |k| {
                if (self.xfer_left == 0) break;
                const x = (self.xfer_x + self.xfer_i % self.xfer_w) & 1023;
                const y = (self.xfer_y + self.xfer_i / self.xfer_w) & 511;
                const px: u16 = @truncate(v >> @intCast(k * 16));
                const idx = y * W + x;
                if (!(self.mask_check and self.vram[idx] & 0x8000 != 0))
                    self.vram[idx] = px | (if (self.mask_set) @as(u16, 0x8000) else 0);
                self.xfer_i += 1;
                self.xfer_left -= 1;
            }
            if (self.xfer_left == 0) self.xfer_in = false;
            return;
        }
        if (self.poly_line) {
            if ((v & 0xF000F000) == 0x50005000) {
                self.poly_line = false;
                self.cmd_len = 0;
                return;
            }
            self.cmd[self.cmd_len] = v;
            self.cmd_len += 1;
            const shaded = (self.cmd[0] >> 24) & 0x10 != 0;
            const per: u32 = if (shaded) 2 else 1;
            // precisa de 2 vértices; desenha o segmento e desliza
            const total: u32 = 1 + per * 2;
            if (self.cmd_len == total) {
                self.drawLineCmd(shaded);
                // desliza o último vértice para a posição do primeiro
                if (shaded) {
                    self.cmd[1] = self.cmd[3];
                    self.cmd[2] = self.cmd[4];
                    self.cmd_len = 3;
                } else {
                    self.cmd[1] = self.cmd[2];
                    self.cmd_len = 2;
                }
            }
            return;
        }
        if (self.cmd_len == 0) {
            const op: u8 = @truncate(v >> 24);
            self.cmd_need = cmdLen(op);
            if (self.cmd_need == 0xFF) {
                self.cmd[0] = v;
                self.cmd_len = 1;
                self.poly_line = true;
                return;
            }
        }
        self.cmd[self.cmd_len] = v;
        self.cmd_len += 1;
        if (self.cmd_len < self.cmd_need) return;
        self.cmd_len = 0;
        self.execute();
    }

    fn execute(self: *Gpu) void {
        const c = &self.cmd;
        const op: u8 = @truncate(c[0] >> 24);
        self.dbg_ops[op] += 1;
        switch (op) {
            0x00, 0x01 => {},
            0x02 => {
                const color = rgb15(c[0]);
                const x0 = c[1] & 0x3F0;
                const y0 = (c[1] >> 16) & 0x1FF;
                const w = ((c[2] & 0x3FF) + 15) & ~@as(u32, 15);
                const h = (c[2] >> 16) & 0x1FF;
                var y: u32 = 0;
                while (y < h) : (y += 1) {
                    var x: u32 = 0;
                    while (x < w) : (x += 1) self.vram[((y0 + y) & 511) * W + ((x0 + x) & 1023)] = color;
                }
            },
            0x20...0x3F => self.drawPolyCmd(op),
            0x40...0x5F => self.drawLineCmd(op & 0x10 != 0),
            0x60...0x7F => self.drawRectCmd(op),
            0x80...0x9F => {
                if (self.dbg_cp_n < 8) {
                    self.dbg_cp[self.dbg_cp_n] = .{ c[1], c[2], c[3] };
                    self.dbg_cp_n += 1;
                }
                const sx = c[1] & 0x3FF;
                const sy = (c[1] >> 16) & 0x1FF;
                const dx = c[2] & 0x3FF;
                const dy = (c[2] >> 16) & 0x1FF;
                var w = c[3] & 0x3FF;
                var h = (c[3] >> 16) & 0x1FF;
                if (w == 0) w = 0x400;
                if (h == 0) h = 0x200;
                var y: u32 = 0;
                while (y < h) : (y += 1) {
                    var x: u32 = 0;
                    while (x < w) : (x += 1) {
                        const px = self.vram[((sy + y) & 511) * W + ((sx + x) & 1023)];
                        self.vram[((dy + y) & 511) * W + ((dx + x) & 1023)] = px;
                    }
                }
            },
            0xA0...0xBF, 0xC0...0xDF => {
                self.xfer_x = c[1] & 0x3FF;
                self.xfer_y = (c[1] >> 16) & 0x1FF;
                self.xfer_w = c[2] & 0x3FF;
                self.xfer_h = (c[2] >> 16) & 0x1FF;
                if (self.xfer_w == 0) self.xfer_w = 0x400;
                if (self.xfer_h == 0) self.xfer_h = 0x200;
                self.xfer_i = 0;
                const n = self.xfer_w * self.xfer_h;
                if (op < 0xC0) {
                    self.xfer_left = n;
                    self.xfer_in = true;
                } else {
                    self.read_left = (n + 1) / 2;
                }
            },
            0xE1 => self.texpage = c[0] & 0x3FFF,
            0xE2 => self.tex_win = c[0] & 0xFFFFF,
            0xE3 => {
                self.da_x1 = @intCast(c[0] & 0x3FF);
                self.da_y1 = @intCast((c[0] >> 10) & 0x1FF);
            },
            0xE4 => {
                self.da_x2 = @intCast(c[0] & 0x3FF);
                self.da_y2 = @intCast((c[0] >> 10) & 0x1FF);
            },
            0xE5 => {
                self.off_x = sext11(c[0] & 0x7FF);
                self.off_y = sext11((c[0] >> 11) & 0x7FF);
            },
            0xE6 => {
                self.mask_set = c[0] & 1 != 0;
                self.mask_check = c[0] & 2 != 0;
            },
            else => {},
        }
    }

    fn sext11(v: u32) i32 {
        return @as(i32, @bitCast(v << 21)) >> 21;
    }

    fn rgb15(c: u32) u16 {
        const r: u16 = @truncate((c >> 3) & 0x1F);
        const g: u16 = @truncate((c >> 11) & 0x1F);
        const b: u16 = @truncate((c >> 19) & 0x1F);
        return r | (g << 5) | (b << 10);
    }

    fn vxy(self: *Gpu, w: u32) struct { x: i32, y: i32 } {
        return .{ .x = sext11(w & 0x7FF) + self.off_x, .y = sext11((w >> 16) & 0x7FF) + self.off_y };
    }

    fn drawPolyCmd(self: *Gpu, op: u8) void {
        const c = &self.cmd;
        const quad = op & 0x08 != 0;
        const tex = op & 0x04 != 0;
        const shaded = op & 0x10 != 0;
        const semi = op & 0x02 != 0;
        const raw = op & 0x01 != 0;
        const nv: usize = if (quad) 4 else 3;
        var v: [4]Vtx = undefined;
        var idx: usize = 0;
        var clut: u32 = 0;
        var page: u32 = self.texpage;
        for (0..nv) |i| {
            const color = if (i == 0 or !shaded) c[0] else blk: {
                const cc = c[idx];
                idx += 1;
                break :blk cc;
            };
            if (i == 0) idx = 1;
            const p = self.vxy(c[idx]);
            idx += 1;
            v[i] = .{ .x = p.x, .y = p.y, .r = @intCast(color & 0xFF), .g = @intCast((color >> 8) & 0xFF), .b = @intCast((color >> 16) & 0xFF) };
            if (tex) {
                const t = c[idx];
                idx += 1;
                v[i].u = @intCast(t & 0xFF);
                v[i].v = @intCast((t >> 8) & 0xFF);
                if (i == 0) clut = t >> 16;
                if (i == 1) page = (t >> 16) & 0x3FFF;
            }
        }
        if (tex) self.texpage = (self.texpage & ~@as(u32, 0x9FF)) | (page & 0x9FF);
        const mode = Mode{ .tex = tex, .shaded = shaded, .semi = semi, .raw = raw, .clut = clut, .page = if (tex) page else self.texpage };
        self.triangle(v[0], v[1], v[2], mode);
        if (quad) self.triangle(v[1], v[2], v[3], mode);
    }

    fn drawRectCmd(self: *Gpu, op: u8) void {
        const c = &self.cmd;
        const tex = op & 0x04 != 0;
        const semi = op & 0x02 != 0;
        const raw = op & 0x01 != 0;
        const p = self.vxy(c[1]);
        var i: usize = 2;
        var tu0: i32 = 0;
        var v0: i32 = 0;
        var clut: u32 = 0;
        if (tex) {
            tu0 = @intCast(c[2] & 0xFF);
            v0 = @intCast((c[2] >> 8) & 0xFF);
            clut = c[2] >> 16;
            i = 3;
        }
        const w: i32, const h: i32 = switch ((op >> 3) & 3) {
            0 => .{ @intCast(c[i] & 0x3FF), @intCast((c[i] >> 16) & 0x1FF) },
            1 => .{ 1, 1 },
            2 => .{ 8, 8 },
            else => .{ 16, 16 },
        };
        const mode = Mode{ .tex = tex, .shaded = false, .semi = semi, .raw = raw, .clut = clut, .page = self.texpage };
        const cr: i32 = @intCast(c[0] & 0xFF);
        const cg: i32 = @intCast((c[0] >> 8) & 0xFF);
        const cb: i32 = @intCast((c[0] >> 16) & 0xFF);
        const flipx = self.texpage & (1 << 12) != 0;
        const flipy = self.texpage & (1 << 13) != 0;
        var y: i32 = 0;
        while (y < h) : (y += 1) {
            const py = p.y + y;
            if (py < self.da_y1 or py > self.da_y2) continue;
            var x: i32 = 0;
            while (x < w) : (x += 1) {
                const px = p.x + x;
                if (px < self.da_x1 or px > self.da_x2) continue;
                const tu = if (flipx) tu0 - x else tu0 + x;
                const tv = if (flipy) v0 - y else v0 + y;
                self.plot(px, py, cr, cg, cb, tu & 0xFF, tv & 0xFF, mode);
            }
        }
    }

    fn drawLineCmd(self: *Gpu, shaded: bool) void {
        const c = &self.cmd;
        const c0 = c[0];
        const p0 = self.vxy(c[1]);
        const c1 = if (shaded) c[2] else c0;
        const p1 = self.vxy(if (shaded) c[3] else c[2]);
        const semi = (c0 >> 24) & 0x02 != 0;
        const mode = Mode{ .tex = false, .shaded = shaded, .semi = semi, .raw = false, .clut = 0, .page = self.texpage };
        const dx = p1.x - p0.x;
        const dy = p1.y - p0.y;
        const steps: i32 = @intCast(@max(@abs(dx), @abs(dy)));
        if (steps > 1024) return;
        var s: i32 = 0;
        while (s <= steps) : (s += 1) {
            const t = if (steps == 0) 0 else @divTrunc(s * 65536, steps);
            const x = p0.x + @divTrunc(dx * t, 65536);
            const y = p0.y + @divTrunc(dy * t, 65536);
            if (x < self.da_x1 or x > self.da_x2 or y < self.da_y1 or y > self.da_y2) continue;
            const r = lerp(c0 & 0xFF, c1 & 0xFF, t);
            const g = lerp((c0 >> 8) & 0xFF, (c1 >> 8) & 0xFF, t);
            const b = lerp((c0 >> 16) & 0xFF, (c1 >> 16) & 0xFF, t);
            self.plot(x, y, r, g, b, 0, 0, mode);
        }
    }

    fn lerp(a: u32, b: u32, t: i32) i32 {
        const ai: i32 = @intCast(a);
        const bi: i32 = @intCast(b);
        return ai + @divTrunc((bi - ai) * t, 65536);
    }

    const Mode = struct { tex: bool, shaded: bool, semi: bool, raw: bool, clut: u32, page: u32 };

    fn edge(ax: i32, ay: i32, bx: i32, by: i32, px: i32, py: i32) i64 {
        return @as(i64, bx - ax) * @as(i64, py - ay) - @as(i64, by - ay) * @as(i64, px - ax);
    }

    fn triangle(self: *Gpu, a0: Vtx, b0: Vtx, c0: Vtx, m: Mode) void {
        var a = a0;
        var b = b0;
        const c = c0;
        var area = edge(a.x, a.y, b.x, b.y, c.x, c.y);
        if (area == 0) return;
        if (area < 0) {
            const t = a;
            a = b;
            b = t;
            area = -area;
        }
        // limites: polígonos maiores que 1023x511 são descartados pelo hardware
        const minx = @max(@min(a.x, @min(b.x, c.x)), self.da_x1);
        const maxx = @min(@max(a.x, @max(b.x, c.x)), self.da_x2);
        const miny = @max(@min(a.y, @min(b.y, c.y)), self.da_y1);
        const maxy = @min(@max(a.y, @max(b.y, c.y)), self.da_y2);
        if (@max(a.x, @max(b.x, c.x)) - @min(a.x, @min(b.x, c.x)) >= 1024) return;
        if (@max(a.y, @max(b.y, c.y)) - @min(a.y, @min(b.y, c.y)) >= 512) return;
        var y = miny;
        while (y <= maxy) : (y += 1) {
            var x = minx;
            while (x <= maxx) : (x += 1) {
                const w0 = edge(b.x, b.y, c.x, c.y, x, y);
                const w1 = edge(c.x, c.y, a.x, a.y, x, y);
                const w2 = edge(a.x, a.y, b.x, b.y, x, y);
                if (w0 < 0 or w1 < 0 or w2 < 0) continue;
                // regra top-left aproximada: exclui a borda direita/inferior
                if ((w0 == 0 and !topLeft(b, c)) or (w1 == 0 and !topLeft(c, a)) or (w2 == 0 and !topLeft(a, b))) continue;
                var r: i32 = a.r;
                var g: i32 = a.g;
                var bl: i32 = a.b;
                if (m.shaded) {
                    r = @intCast(@divTrunc(w0 * a.r + w1 * b.r + w2 * c.r, area));
                    g = @intCast(@divTrunc(w0 * a.g + w1 * b.g + w2 * c.g, area));
                    bl = @intCast(@divTrunc(w0 * a.b + w1 * b.b + w2 * c.b, area));
                }
                var u: i32 = 0;
                var v: i32 = 0;
                if (m.tex) {
                    u = @intCast(@divTrunc(w0 * a.u + w1 * b.u + w2 * c.u, area));
                    v = @intCast(@divTrunc(w0 * a.v + w1 * b.v + w2 * c.v, area));
                }
                self.plot(x, y, r, g, bl, u, v, m);
            }
        }
    }

    fn topLeft(p: Vtx, q: Vtx) bool {
        return (p.y == q.y and q.x < p.x) or (q.y > p.y);
    }

    fn texel(self: *Gpu, tu0: i32, v0: i32, m: Mode) u16 {
        // janela de textura
        const mx: u32 = (self.tex_win & 0x1F) * 8;
        const my: u32 = ((self.tex_win >> 5) & 0x1F) * 8;
        const ox: u32 = ((self.tex_win >> 10) & 0x1F) * 8;
        const oy: u32 = ((self.tex_win >> 15) & 0x1F) * 8;
        const u: u32 = ((@as(u32, @intCast(tu0 & 0xFF)) & ~mx) | (ox & mx));
        const v: u32 = ((@as(u32, @intCast(v0 & 0xFF)) & ~my) | (oy & my));
        const px: u32 = (m.page & 0xF) * 64;
        const py: u32 = ((m.page >> 4) & 1) * 256;
        const depth = (m.page >> 7) & 3;
        const cx: u32 = (m.clut & 0x3F) * 16;
        const cy: u32 = (m.clut >> 6) & 0x1FF;
        switch (depth) {
            0 => {
                const word = self.vram[((py + v) & 511) * W + ((px + u / 4) & 1023)];
                const idx = (word >> @intCast((u & 3) * 4)) & 0xF;
                return self.vram[cy * W + ((cx + idx) & 1023)];
            },
            1 => {
                const word = self.vram[((py + v) & 511) * W + ((px + u / 2) & 1023)];
                const idx = (word >> @intCast((u & 1) * 8)) & 0xFF;
                return self.vram[cy * W + ((cx + idx) & 1023)];
            },
            else => return self.vram[((py + v) & 511) * W + ((px + u) & 1023)],
        }
    }

    fn plot(self: *Gpu, x: i32, y: i32, r0: i32, g0: i32, b0: i32, u: i32, v: i32, m: Mode) void {
        if (x < 0 or y < 0 or x >= W or y >= H) return;
        const idx: usize = @as(usize, @intCast(y)) * W + @as(usize, @intCast(x));
        if (self.mask_check and self.vram[idx] & 0x8000 != 0) return;
        var r: i32 = 0;
        var g: i32 = 0;
        var b: i32 = 0;
        var semi_px = m.semi;
        if (m.tex) {
            const t = self.texel(u, v, m);
            if (t == 0) return; // transparente
            semi_px = m.semi and (t & 0x8000) != 0;
            const tr: i32 = @intCast(t & 0x1F);
            const tg: i32 = @intCast((t >> 5) & 0x1F);
            const tb: i32 = @intCast((t >> 10) & 0x1F);
            if (m.raw) {
                r = tr;
                g = tg;
                b = tb;
            } else {
                r = @min(31, @divTrunc(tr * r0, 128));
                g = @min(31, @divTrunc(tg * g0, 128));
                b = @min(31, @divTrunc(tb * b0, 128));
            }
        } else {
            r = r0 >> 3;
            g = g0 >> 3;
            b = b0 >> 3;
        }
        if (semi_px) {
            const d = self.vram[idx];
            const dr: i32 = @intCast(d & 0x1F);
            const dg: i32 = @intCast((d >> 5) & 0x1F);
            const db: i32 = @intCast((d >> 10) & 0x1F);
            switch ((m.page >> 5) & 3) {
                0 => {
                    r = (dr + r) >> 1;
                    g = (dg + g) >> 1;
                    b = (db + b) >> 1;
                },
                1 => {
                    r = @min(31, dr + r);
                    g = @min(31, dg + g);
                    b = @min(31, db + b);
                },
                2 => {
                    r = @max(0, dr - r);
                    g = @max(0, dg - g);
                    b = @max(0, db - b);
                },
                else => {
                    r = @min(31, dr + (r >> 2));
                    g = @min(31, dg + (g >> 2));
                    b = @min(31, db + (b >> 2));
                },
            }
        }
        var out: u16 = @intCast(r | (g << 5) | (b << 10));
        if (self.mask_set) out |= 0x8000;
        self.vram[idx] = out;
    }
};
