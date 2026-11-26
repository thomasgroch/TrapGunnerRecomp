//! ISO9660 mínimo (diretório raiz) sobre o leitor de setores do host.
const std = @import("std");
const SectorReader = @import("psx.zig").SectorReader;

pub const Entry = struct { lba: u32, size: u32 };

fn nameEq(iso: []const u8, want: []const u8) bool {
    const base = if (std.mem.indexOfScalar(u8, iso, ';')) |i| iso[0..i] else iso;
    return std.ascii.eqlIgnoreCase(base, want);
}

/// Procura `name` no diretório raiz. Setores MODE2/2352 (dados em +24).
pub fn findRoot(read: SectorReader, name: []const u8) ?Entry {
    var sec: [2352]u8 = undefined;
    if (!read(16, &sec)) return null;
    const pvd = sec[24..];
    if (!std.mem.eql(u8, pvd[1..6], "CD001")) return null;
    const root_lba = std.mem.readInt(u32, pvd[156 + 2 ..][0..4], .little);
    const root_size = std.mem.readInt(u32, pvd[156 + 10 ..][0..4], .little);
    var lba = root_lba;
    var left: i64 = root_size;
    while (left > 0) : ({
        lba += 1;
        left -= 2048;
    }) {
        if (!read(lba, &sec)) return null;
        const d = sec[24 .. 24 + 2048];
        var off: usize = 0;
        while (off < 2048 and d[off] != 0) {
            const len = d[off];
            const nl = d[off + 32];
            if (nameEq(d[off + 33 .. off + 33 + nl], name))
                return .{ .lba = std.mem.readInt(u32, d[off + 2 ..][0..4], .little), .size = std.mem.readInt(u32, d[off + 10 ..][0..4], .little) };
            off += len;
        }
    }
    return null;
}

/// Lê um arquivo inteiro para `out` (dados de 2048 bytes por setor).
pub fn readFile(read: SectorReader, e: Entry, out: []u8) bool {
    var sec: [2352]u8 = undefined;
    var left: u32 = e.size;
    var lba = e.lba;
    var pos: usize = 0;
    while (left > 0) : (lba += 1) {
        if (!read(lba, &sec)) return false;
        const n = @min(left, 2048);
        if (pos + n > out.len) return false;
        @memcpy(out[pos .. pos + n], sec[24 .. 24 + n]);
        pos += n;
        left -= n;
    }
    return true;
}
