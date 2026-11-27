//! SPU: 24 voices of ADPCM from SPU RAM (512 KiB), ADSR envelopes,
//! pitch, volume, key on/off, ENDX, DMA/FIFO transfer, plus CD audio (XA)
//! mixing. Output: 44.1 kHz stereo i16 in a ring buffer read by the host.
//! Written from public hardware documentation. Reverb and noise are not
//! emulated (reverb is ignored, noise produces silence).
const std = @import("std");

const pos_tab = [5]i32{ 0, 60, 115, 98, 122 };
const neg_tab = [5]i32{ 0, 0, -52, -55, -60 };

const Phase = enum { off, attack, decay, sustain, release };

const Voice = struct {
    vol_l: u16 = 0,
    vol_r: u16 = 0,
    pitch: u16 = 0,
    start: u32 = 0, // in bytes
    adsr_lo: u16 = 0,
    adsr_hi: u16 = 0,
    repeat: u32 = 0,
    repeat_set: bool = false,
    // state
    addr: u32 = 0,
    counter: u32 = 0,
    samples: [28]i16 = @splat(0),
    hist1: i32 = 0,
    hist2: i32 = 0,
    prev: i16 = 0,
    level: i32 = 0,
    phase: Phase = .off,
    env_wait: u32 = 0,
    block_flags: u8 = 0,
};

pub const Spu = struct {
    ram: [512 * 1024]u8 = undefined,
    voices: [24]Voice = @splat(.{}),
    regs: [512]u16 = @splat(0), // raw shadow of the register area
    main_l: u16 = 0x3FFF,
    main_r: u16 = 0x3FFF,
    cdvol_l: u16 = 0x3FFF,
    cdvol_r: u16 = 0x3FFF,
    cnt: u16 = 0,
    xfer_addr: u32 = 0,
    endx: u32 = 0,

    // output (ring buffer, interleaved stereo)
    out: [16384]i16 = @splat(0),
    out_w: u32 = 0,
    out_r: u32 = 0,

    // CD audio (XA) already resampled to 44.1 kHz, stereo
    cd: [16384]i16 = @splat(0),
    cd_w: u32 = 0,
    cd_r: u32 = 0,
    xa_hist: [2][2]i32 = .{ .{ 0, 0 }, .{ 0, 0 } },
    xa_phase: u32 = 0,

    pub fn reset(self: *Spu) void {
        @memset(&self.ram, 0);
    }

    // ---------------- registers ----------------
    pub fn read(self: *Spu, off: u32) u16 {
        // off = address - 0x1F801C00
        if (off < 0x180) {
            const v = &self.voices[off >> 4];
            return switch (off & 0xF) {
                0x0 => v.vol_l,
                0x2 => v.vol_r,
                0x4 => v.pitch,
                0x6 => @truncate(v.start >> 3),
                0x8 => v.adsr_lo,
                0xA => v.adsr_hi,
                0xC => @intCast(@max(0, v.level)),
                0xE => @truncate(v.repeat >> 3),
                else => 0,
            };
        }
        return switch (off) {
            0x19C => @truncate(self.endx),
            0x19E => @truncate(self.endx >> 16),
            0x1A6 => @truncate(self.xfer_addr >> 3),
            0x1AA => self.cnt,
            0x1AE => self.cnt & 0x3F, // SPUSTAT: mirrors SPUCNT, never busy
            else => self.regs[(off >> 1) & 511],
        };
    }

    pub fn write(self: *Spu, off: u32, val: u16) void {
        self.regs[(off >> 1) & 511] = val;
        if (off < 0x180) {
            const v = &self.voices[off >> 4];
            switch (off & 0xF) {
                0x0 => v.vol_l = val,
                0x2 => v.vol_r = val,
                0x4 => v.pitch = val,
                0x6 => v.start = @as(u32, val) << 3,
                0x8 => v.adsr_lo = val,
                0xA => v.adsr_hi = val,
                0xC => v.level = @as(i16, @bitCast(val)),
                0xE => {
                    v.repeat = @as(u32, val) << 3;
                    v.repeat_set = true;
                },
                else => {},
            }
            return;
        }
        switch (off) {
            0x180 => self.main_l = val,
            0x182 => self.main_r = val,
            0x188 => self.keyOn(val),
            0x18A => self.keyOn(@as(u32, val) << 16),
            0x18C => self.keyOff(val),
            0x18E => self.keyOff(@as(u32, val) << 16),
            0x19C, 0x19E => {}, // ENDX is read-only
            0x1A6 => self.xfer_addr = @as(u32, val) << 3,
            0x1A8 => { // manual FIFO transfer
                std.mem.writeInt(u16, self.ram[self.xfer_addr & 0x7FFFE ..][0..2], val, .little);
                self.xfer_addr = (self.xfer_addr + 2) & 0x7FFFF;
            },
            0x1AA => self.cnt = val,
            0x1B0 => self.cdvol_l = val,
            0x1B2 => self.cdvol_r = val,
            else => {},
        }
    }

    /// Word written by DMA4 (RAM -> SPU).
    pub fn dmaWrite(self: *Spu, w: u32) void {
        std.mem.writeInt(u32, self.ram[self.xfer_addr & 0x7FFFC ..][0..4], w, .little);
        self.xfer_addr = (self.xfer_addr + 4) & 0x7FFFF;
    }
    pub fn dmaRead(self: *Spu) u32 {
        const w = std.mem.readInt(u32, self.ram[self.xfer_addr & 0x7FFFC ..][0..4], .little);
        self.xfer_addr = (self.xfer_addr + 4) & 0x7FFFF;
        return w;
    }

    fn keyOn(self: *Spu, mask: u32) void {
        for (0..24) |i| {
            if (mask & (@as(u32, 1) << @intCast(i)) == 0) continue;
            const v = &self.voices[i];
            v.addr = v.start;
            v.counter = 0;
            v.hist1 = 0;
            v.hist2 = 0;
            v.level = 0;
            v.phase = .attack;
            v.env_wait = 0;
            v.repeat_set = false;
            self.decodeBlock(v);
            self.endx &= ~(@as(u32, 1) << @intCast(i));
        }
    }
    fn keyOff(self: *Spu, mask: u32) void {
        for (0..24) |i| {
            if (mask & (@as(u32, 1) << @intCast(i)) == 0) continue;
            if (self.voices[i].phase != .off) self.voices[i].phase = .release;
        }
    }

    fn decodeBlock(self: *Spu, v: *Voice) void {
        const a = v.addr & 0x7FFF0;
        const hdr = self.ram[a];
        const shift: u5 = @intCast(@min(12, hdr & 0xF));
        const filt: usize = @min(4, (hdr >> 4) & 7);
        v.block_flags = self.ram[a + 1];
        if (v.block_flags & 4 != 0 and !v.repeat_set) v.repeat = a;
        for (0..28) |i| {
            const b = self.ram[a + 2 + i / 2];
            const nib: u4 = @truncate(if (i & 1 == 0) b else b >> 4);
            var s: i32 = @as(i32, @as(i16, @as(i16, @as(i4, @bitCast(nib))) << 12)) >> shift;
            s += @divFloor(v.hist1 * pos_tab[filt] + v.hist2 * neg_tab[filt] + 32, 64);
            s = std.math.clamp(s, -0x8000, 0x7FFF);
            v.hist2 = v.hist1;
            v.hist1 = s;
            v.samples[i] = @intCast(s);
        }
    }

    fn envStep(v: *Voice, rate: u32, decrease: bool, exponential: bool) void {
        const shift: u32 = rate >> 2;
        const base: i32 = if (decrease) -8 + @as(i32, @intCast(rate & 3)) else 7 - @as(i32, @intCast(rate & 3));
        var wait: u32 = @as(u32, 1) << @intCast(@min(31, shift -| 11));
        var step: i32 = base << @intCast(11 -| shift);
        if (exponential and !decrease and v.level > 0x6000) wait *= 4;
        if (exponential and decrease) step = @divTrunc(step * v.level, 0x8000);
        if (v.env_wait > 0) {
            v.env_wait -= 1;
            return;
        }
        v.env_wait = wait - 1;
        v.level = std.math.clamp(v.level + step, 0, 0x7FFF);
    }

    fn envelope(v: *Voice) void {
        switch (v.phase) {
            .off => v.level = 0,
            .attack => {
                envStep(v, (v.adsr_lo >> 8) & 0x7F, false, v.adsr_lo & 0x8000 != 0);
                if (v.level >= 0x7FFF) v.phase = .decay;
            },
            .decay => {
                envStep(v, ((v.adsr_lo >> 4) & 0xF) << 2, true, true);
                const sl: i32 = (@as(i32, v.adsr_lo & 0xF) + 1) * 0x800;
                if (v.level <= sl) v.phase = .sustain;
            },
            .sustain => envStep(v, (v.adsr_hi >> 6) & 0x7F, v.adsr_hi & 0x4000 != 0, v.adsr_hi & 0x8000 != 0),
            .release => {
                envStep(v, (v.adsr_hi & 0x1F) << 2, true, v.adsr_hi & 0x20 != 0);
                if (v.level <= 0) v.phase = .off;
            },
        }
    }

    fn volume(v: u16) i32 {
        if (v & 0x8000 != 0) return 0x3FFF; // sweep: approximated as fixed volume
        return @as(i32, @as(i16, @bitCast(v << 1))) >> 1;
    }

    /// Generates `n` stereo samples at 44.1 kHz.
    pub fn generate(self: *Spu, n: u32) void {
        const enabled = self.cnt & 0x8000 != 0;
        var k: u32 = 0;
        while (k < n) : (k += 1) {
            var l: i32 = 0;
            var r: i32 = 0;
            if (enabled) {
                for (&self.voices, 0..) |*v, vi| {
                    if (v.phase == .off) continue;
                    const idx = v.counter >> 12;
                    const s0: i32 = v.samples[@min(27, idx)];
                    const frac: i32 = @intCast(v.counter & 0xFFF);
                    const s_prev: i32 = v.prev;
                    const s = s_prev + @divTrunc((s0 - s_prev) * frac, 4096);
                    envelope(v);
                    const sv = @divTrunc(s * v.level, 0x8000);
                    l += @divTrunc(sv * volume(v.vol_l), 0x4000);
                    r += @divTrunc(sv * volume(v.vol_r), 0x4000);
                    // advance
                    const step: u32 = @min(0x4000, v.pitch);
                    const before = v.counter >> 12;
                    v.counter += step;
                    if (v.counter >> 12 != before) v.prev = @intCast(s0);
                    while (v.counter >= 28 << 12) {
                        v.counter -= 28 << 12;
                        const flags = v.block_flags;
                        if (flags & 1 != 0) { // end of block
                            self.endx |= @as(u32, 1) << @intCast(vi);
                            if (flags & 2 != 0) {
                                v.addr = v.repeat;
                            } else {
                                v.phase = .off;
                                v.level = 0;
                                break;
                            }
                        } else v.addr = (v.addr + 16) & 0x7FFFF;
                        self.decodeBlock(v);
                    }
                }
                l = @divTrunc(l * volume(self.main_l), 0x4000);
                r = @divTrunc(r * volume(self.main_r), 0x4000);
            }
            // CD audio
            if (self.cd_r != self.cd_w) {
                const cl: i32 = self.cd[self.cd_r & 16383];
                const cr: i32 = self.cd[(self.cd_r + 1) & 16383];
                self.cd_r = (self.cd_r + 2) & 0xFFFFFFF;
                l += @divTrunc(cl * @as(i32, @as(i16, @bitCast(self.cdvol_l))), 0x8000);
                r += @divTrunc(cr * @as(i32, @as(i16, @bitCast(self.cdvol_r))), 0x8000);
            }
            self.out[self.out_w & 16383] = @intCast(std.math.clamp(l, -0x8000, 0x7FFF));
            self.out[(self.out_w + 1) & 16383] = @intCast(std.math.clamp(r, -0x8000, 0x7FFF));
            self.out_w +%= 2;
        }
    }


    // ---------------- XA-ADPCM (CD) ----------------

    /// Decodes an XA audio sector (raw, 2352 bytes) and pushes it already
    /// resampled to 44.1 kHz stereo into the CD buffer.
    pub fn xaSector(self: *Spu, sec: *const [2352]u8) void {
        const coding = sec[19];
        const stereo = coding & 1 != 0;
        const rate: u32 = if (coding & 4 != 0) 18900 else 37800;
        const bits8 = coding & 0x10 != 0;
        if (bits8) return; // 8-bit XA (rare) not supported
        var pcm: [4032]i16 = undefined; // 18 groups * 8 units * 28 samples
        var n: usize = 0;
        const data = sec[24..];
        for (0..18) |g| {
            const grp = data[g * 128 ..][0..128];
            for (0..8) |u| {
                const hdr = grp[4 + u];
                const shift: u5 = @intCast(@min(12, hdr & 0xF));
                const filt: usize = @min(4, (hdr >> 4) & 3);
                const ch: usize = if (stereo) u & 1 else 0;
                for (0..28) |s| {
                    const byte = grp[16 + s * 4 + u / 2];
                    const nib: u4 = @truncate(if (u & 1 == 0) byte else byte >> 4);
                    var v: i32 = @as(i32, @as(i16, @as(i16, @as(i4, @bitCast(nib))) << 12)) >> shift;
                    const h = &self.xa_hist[ch];
                    v += @divFloor(h[0] * pos_tab[filt] + h[1] * neg_tab[filt] + 32, 64);
                    v = std.math.clamp(v, -0x8000, 0x7FFF);
                    h[1] = h[0];
                    h[0] = v;
                    if (n < pcm.len) {
                        pcm[n] = @intCast(v);
                        n += 1;
                    }
                }
            }
        }
        // pcm is in unit order (each unit = 28 samples of one channel).
        // Rebuild L/R frames, unit by unit.
        var frames: [4032][2]i16 = undefined;
        var nf: usize = 0;
        if (stereo) {
            var u: usize = 0;
            while (u + 1 < n / 28) : (u += 2) {
                for (0..28) |s| {
                    frames[nf] = .{ pcm[u * 28 + s], pcm[(u + 1) * 28 + s] };
                    nf += 1;
                }
            }
        } else {
            for (pcm[0..n]) |s| {
                frames[nf] = .{ s, s };
                nf += 1;
            }
        }
        // resample (nearest neighbour with fractional accumulator) to 44100
        var i: usize = 0;
        while (i < nf) {
            const f = frames[i];
            self.cd[self.cd_w & 16383] = f[0];
            self.cd[(self.cd_w + 1) & 16383] = f[1];
            self.cd_w = (self.cd_w + 2) & 0xFFFFFFF;
            self.xa_phase += rate;
            while (self.xa_phase >= 44100) {
                self.xa_phase -= 44100;
                i += 1;
            }
        }
    }
};
