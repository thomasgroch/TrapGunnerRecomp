//! Porta de controle/memory card (SIO0): controle digital nas duas portas.
//! Memory card: ausente (sem ACK).
const Psx = @import("psx.zig").Psx;

pub const Sio = struct {
    ctrl: u16 = 0,
    mode: u16 = 0,
    baud: u16 = 0,
    rx: u8 = 0xFF,
    rx_full: bool = false,
    ack: bool = false,
    irq_at: u64 = 0,
    step: u8 = 0,
    device: u8 = 0, // 0=nenhum, 1=pad
    /// Botões (ativo em nível baixo) por porta, fornecidos pelo host.
    buttons: [2]u16 = .{ 0xFFFF, 0xFFFF },
    connected: [2]bool = .{ true, false },

    pub fn read(self: *Sio, off: u32, size: u8) u32 {
        _ = size;
        return switch (off) {
            0x0 => blk: {
                const v = self.rx;
                self.rx_full = false;
                self.rx = 0xFF;
                break :blk v;
            },
            0x4 => blk: {
                var s: u32 = 0x5; // TX pronto
                if (self.rx_full) s |= 0x2;
                if (self.ack) s |= 0x80;
                if (self.irq_at != 0 and false) s |= 0x200;
                break :blk s;
            },
            0x8 => self.mode,
            0xA => self.ctrl,
            0xE => self.baud,
            else => 0,
        };
    }

    pub fn write(self: *Sio, off: u32, v: u32, size: u8, psx: *Psx) void {
        _ = size;
        switch (off) {
            0x0 => self.transfer(@truncate(v), psx),
            0x8 => self.mode = @truncate(v),
            0xA => {
                self.ctrl = @truncate(v);
                if (v & 0x40 != 0) { // reset
                    self.ctrl = 0;
                    self.step = 0;
                }
                if (v & 0x10 != 0) self.ack = false; // ack de IRQ
                if (v & 0x2 == 0) { // /SEL desativado: fim da transação
                    self.step = 0;
                    self.device = 0;
                }
            },
            0xE => self.baud = @truncate(v),
            else => {},
        }
    }

    fn transfer(self: *Sio, b: u8, psx: *Psx) void {
        const port: usize = if (self.ctrl & 0x2000 != 0) 1 else 0;
        var reply: u8 = 0xFF;
        var do_ack = false;
        if (self.step == 0) {
            if (b == 0x01 and self.connected[port]) {
                self.device = 1;
                reply = 0xFF;
                do_ack = true;
                self.step = 1;
            } else {
                self.device = 0; // memory card (0x81) ou nada: sem resposta
            }
        } else if (self.device == 1) {
            const btn = self.buttons[port];
            switch (self.step) {
                1 => {
                    reply = 0x41; // ID: controle digital
                    do_ack = true;
                },
                2 => {
                    reply = 0x5A;
                    do_ack = true;
                },
                3 => {
                    reply = @truncate(btn);
                    do_ack = true;
                },
                4 => {
                    reply = @truncate(btn >> 8);
                    do_ack = false;
                },
                else => {},
            }
            self.step += 1;
            if (!do_ack) {
                self.step = 0;
                self.device = 0;
            }
        }
        self.rx = reply;
        self.rx_full = true;
        if (do_ack) self.irq_at = psx.cycles + 1500;
    }

    pub fn tick(self: *Sio, psx: *Psx) void {
        if (self.irq_at != 0 and psx.cycles >= self.irq_at) {
            self.irq_at = 0;
            self.ack = true;
            if (self.ctrl & 0x1000 != 0) psx.raise(.pad);
        }
    }
};
