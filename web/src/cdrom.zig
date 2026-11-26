//! Controlador de CD-ROM (subconjunto usado por libcd): Getstat, Setloc,
//! ReadN/ReadS, Pause, Init, Setmode, SeekL, GetTN/GetTD, GetlocL/P, Test, GetID.
//! Respostas com IRQ atrasado por ciclos; dados de setor via FIFO + DMA3.
const std = @import("std");
const Psx = @import("psx.zig").Psx;
const SectorReader = @import("psx.zig").SectorReader;

const DELAY_ACK: u64 = 50_000;
const DELAY_READ_1X: u64 = 33868800 / 75;

pub const Cdrom = struct {
    reader: ?SectorReader = null,
    index: u2 = 0,
    ie: u8 = 0,
    iflag: u8 = 0,
    params: [16]u8 = @splat(0),
    nparams: u8 = 0,
    resp: [16]u8 = @splat(0),
    resp_len: u8 = 0,
    resp_pos: u8 = 0,
    // eventos pendentes (resposta 2 ou leitura)
    pend_at: u64 = 0,
    pend_int: u8 = 0,
    pend_resp: [16]u8 = @splat(0),
    pend_len: u8 = 0,
    stat: u8 = 0x02, // motor ligado
    mode: u8 = 0,
    loc: u32 = 0,
    reading: bool = false,
    next_read_at: u64 = 0,
    // setor
    sector: [2352]u8 = @splat(0),
    data: [2352]u8 = @splat(0),
    data_len: u32 = 0,
    data_pos: u32 = 0,
    want_data: bool = false,
    ready_sector: bool = false,
    filter_file: u8 = 0,
    filter_chan: u8 = 0,
    sector_seq: u32 = 0,
    cur_lba: u32 = 0,
    dlog: [32][4]u32 = undefined,
    dlog_n: u32 = 0,
    loaded_seq: u32 = 0,
    dbg: [48][4]u32 = undefined,
    dbg_n: u32 = 0,

    fn bcd(v: u8) u8 {
        return (v >> 4) * 10 + (v & 0xF);
    }
    fn tobcd(v: u32) u8 {
        return @intCast(((v / 10) << 4) | (v % 10));
    }

    pub fn read(self: *Cdrom, reg: u2, psx: *Psx) u8 {
        _ = psx;
        switch (reg) {
            0 => {
                var s: u8 = self.index;
                s |= 1 << 3; // param fifo vazia
                if (self.nparams < 16) s |= 1 << 4;
                if (self.resp_pos < self.resp_len) s |= 1 << 5;
                if (self.data_pos < self.data_len) s |= 1 << 6;
                return s;
            },
            1 => {
                if (self.resp_pos < self.resp_len) {
                    const v = self.resp[self.resp_pos];
                    self.resp_pos += 1;
                    return v;
                }
                return 0;
            },
            2 => {
                if (self.data_pos < self.data_len) {
                    const b = self.data[self.data_pos];
                    self.data_pos += 1;
                    return b;
                }
                return 0;
            },
            3 => return if (self.index & 1 == 0) self.ie | 0xE0 else self.iflag | 0xE0,
        }
    }

    pub fn dataWord(self: *Cdrom) u32 {
        var w: u32 = 0;
        for (0..4) |k| {
            var b: u8 = 0;
            if (self.data_pos < self.data_len) {
                b = self.data[self.data_pos];
                self.data_pos += 1;
            }
            w |= @as(u32, b) << @intCast(k * 8);
        }
        return w;
    }

    pub fn write(self: *Cdrom, reg: u2, v: u8, psx: *Psx) void {
        switch (reg) {
            0 => self.index = @truncate(v),
            1 => switch (self.index) {
                0 => self.command(v, psx),
                else => {},
            },
            2 => switch (self.index) {
                0 => if (self.nparams < 16) {
                    self.params[self.nparams] = v;
                    self.nparams += 1;
                },
                1 => self.ie = v & 0x1F,
                else => {},
            },
            3 => switch (self.index) {
                0 => {
                    // BFRD: liberar setor para leitura
                    if (v & 0x80 != 0) {
                        if (self.data_pos >= self.data_len or self.sector_seq != self.loaded_seq) self.loadData();
                        self.want_data = true;
                    } else {
                        self.want_data = false;
                        self.data_len = 0;
                        self.data_pos = 0;
                    }
                },
                1 => {
                    self.iflag &= ~(v & 0x1F);
                    if (v & 0x40 != 0) self.nparams = 0;
                },
                else => {},
            },
        }
    }

    fn loadData(self: *Cdrom) void {
        if (!self.ready_sector) return;
        if (self.cur_lba >= 10497 and self.cur_lba < 10520 and self.dlog_n < 32) {
            self.dlog[self.dlog_n] = .{ self.cur_lba, self.data_pos, self.data_len, self.mode };
            self.dlog_n += 1;
        }
        self.loaded_seq = self.sector_seq;
        if (self.mode & 0x20 != 0) {
            @memcpy(self.data[0..2340], self.sector[12..2352]);
            self.data_len = 2340;
        } else {
            @memcpy(self.data[0..2048], self.sector[24 .. 24 + 2048]);
            self.data_len = 2048;
        }
        self.data_pos = 0;
    }

    fn ack(self: *Cdrom, int: u8, bytes: []const u8) void {
        @memcpy(self.resp[0..bytes.len], bytes);
        self.resp_len = @intCast(bytes.len);
        self.resp_pos = 0;
        self.iflag = (self.iflag & ~@as(u8, 7)) | int;
    }

    fn later(self: *Cdrom, psx: *Psx, delay: u64, int: u8, bytes: []const u8) void {
        self.pend_at = psx.cycles + delay;
        self.pend_int = int;
        @memcpy(self.pend_resp[0..bytes.len], bytes);
        self.pend_len = @intCast(bytes.len);
    }

    fn command(self: *Cdrom, cmd: u8, psx: *Psx) void {
        const p = self.params;
        if (self.dbg_n < 48 and cmd != 1) {
            self.dbg[self.dbg_n] = .{ cmd, p[0], self.loc, @truncate(psx.frame) };
            self.dbg_n += 1;
        }
        defer self.nparams = 0;
        switch (cmd) {
            0x01 => self.ackNow(psx, &.{self.stat}),
            0x02 => { // Setloc
                const m: u32 = bcd(p[0]);
                const s: u32 = bcd(p[1]);
                const f: u32 = bcd(p[2]);
                self.loc = (m * 60 + s) * 75 + f;
                self.loc -|= 150;
                self.ackNow(psx, &.{self.stat});
            },
            0x06, 0x1B => { // ReadN / ReadS
                self.reading = true;
                self.stat = 0x22;
                self.next_read_at = psx.cycles + self.readDelay();
                self.ackNow(psx, &.{self.stat});
            },
            0x08 => { // Stop
                self.reading = false;
                self.stat = 0x00;
                self.ackNow(psx, &.{0x02});
                self.later(psx, DELAY_ACK * 10, 2, &.{self.stat});
            },
            0x09 => { // Pause
                self.ackNow(psx, &.{self.stat});
                self.reading = false;
                self.stat = 0x02;
                self.later(psx, DELAY_ACK * 2, 2, &.{self.stat});
            },
            0x0A => { // Init
                self.ackNow(psx, &.{self.stat});
                self.reading = false;
                self.mode = 0;
                self.stat = 0x02;
                self.later(psx, DELAY_ACK * 4, 2, &.{self.stat});
            },
            0x0B, 0x0C => self.ackNow(psx, &.{self.stat}), // Mute/Demute
            0x0D => { // Setfilter
                self.filter_file = p[0];
                self.filter_chan = p[1];
                self.ackNow(psx, &.{self.stat});
            },
            0x0E => { // Setmode
                self.mode = p[0];
                self.ackNow(psx, &.{self.stat});
            },
            0x10 => { // GetlocL
                self.ackNow(psx, self.sector[12..20]);
            },
            0x11 => { // GetlocP
                const l = self.loc + 150;
                self.ackNow(psx, &.{ 1, 1, tobcd(self.loc / 75 / 60), tobcd((self.loc / 75) % 60), tobcd(self.loc % 75), tobcd(l / 75 / 60), tobcd((l / 75) % 60), tobcd(l % 75) });
            },
            0x13 => self.ackNow(psx, &.{ self.stat, 0x01, 0x01 }), // GetTN
            0x14 => { // GetTD
                if (p[0] == 0) {
                    // fim do disco (708410640 / 2352 setores + 2s)
                    const total: u32 = 301195 + 150;
                    self.ackNow(psx, &.{ self.stat, tobcd(total / 75 / 60), tobcd((total / 75) % 60) });
                } else self.ackNow(psx, &.{ self.stat, 0x00, 0x02 });
            },
            0x15, 0x16 => { // SeekL / SeekP
                self.reading = false;
                self.stat = 0x42;
                self.ackNow(psx, &.{self.stat});
                self.stat = 0x02;
                self.later(psx, DELAY_ACK * 2, 2, &.{self.stat});
            },
            0x19 => { // Test
                if (p[0] == 0x20) self.ackNow(psx, &.{ 0x94, 0x09, 0x19, 0xC0 }) else self.ackNow(psx, &.{self.stat});
            },
            0x1A => { // GetID: disco licenciado NTSC-U ("SCEA")
                self.ackNow(psx, &.{self.stat});
                self.later(psx, DELAY_ACK * 2, 2, &.{ 0x02, 0x00, 0x20, 0x00, 'S', 'C', 'E', 'A' });
            },
            0x1E => { // ReadTOC
                self.ackNow(psx, &.{self.stat});
                self.later(psx, DELAY_ACK * 8, 2, &.{self.stat});
            },
            else => self.ackErr(psx),
        }
    }

    fn ackNow(self: *Cdrom, psx: *Psx, bytes: []const u8) void {
        self.ack(3, bytes);
        psx.raise(.cdrom);
    }
    fn ackErr(self: *Cdrom, psx: *Psx) void {
        self.ack(5, &.{ self.stat | 1, 0x40 });
        psx.raise(.cdrom);
    }

    fn readDelay(self: *Cdrom) u64 {
        return if (self.mode & 0x80 != 0) DELAY_READ_1X / 2 else DELAY_READ_1X;
    }

    pub fn tick(self: *Cdrom, psx: *Psx) void {
        // resposta diferida (INT2): só entrega quando o INT anterior foi reconhecido
        if (self.pend_int != 0 and psx.cycles >= self.pend_at and self.iflag & 7 == 0) {
            self.ack(self.pend_int, self.pend_resp[0..self.pend_len]);
            self.pend_int = 0;
            psx.raise(.cdrom);
        }
        if (self.reading and psx.cycles >= self.next_read_at and self.iflag & 7 == 0) {
            self.next_read_at = psx.cycles + self.readDelay();
            var tmp: [2352]u8 = undefined;
            const ok = if (self.reader) |r| r(self.loc, &tmp) else false;
            self.loc += 1;
            // setores de áudio XA (submodo bit 2) vão para a SPU, não para a CPU:
            // descarta sem tocar no buffer do setor de dados anterior
            if (ok and self.mode & 0x40 != 0 and tmp[18] & 0x04 != 0) return;
            self.sector = tmp;
            self.cur_lba = self.loc - 1;
            self.ready_sector = ok;
            self.sector_seq +%= 1;
            self.ack(1, &.{self.stat});
            psx.raise(.cdrom);
        }
    }
};
