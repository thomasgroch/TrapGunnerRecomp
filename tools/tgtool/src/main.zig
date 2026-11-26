//! tgtool — helper de setup do TrapGunnerRecomp (Zig).
//!
//!   tgtool verify  <Trap Gunner.bin>          confere o SHA-1 do dump (Redump, SLUS-00679)
//!   tgtool list    <Trap Gunner.bin>          lista os arquivos da ISO9660
//!   tgtool extract <Trap Gunner.bin> <outdir> extrai SLUS_006.79 da ISO9660 (MODE2/2352)
//!   tgtool setup   <Trap Gunner.cue>          verify + extract em disc/ + aponta game.toml
//!
//! Nenhum dado do jogo vem no repositório: tudo sai do disco do próprio jogador.
const std = @import("std");
const Io = std.Io;

pub const known_sha1 = "258d840cc7cbb8900d76fd7d1ca499b4085ad6e1";
pub const known_size: u64 = 708410640;
pub const boot_exe = "SLUS_006.79";

const raw_sector = 2352;
const user_off = 24; // MODE2 Form1: 12 sync + 4 header + 8 subheader
const user_len = 2048;

fn die(comptime fmt: []const u8, args: anytype) noreturn {
    std.debug.print("tgtool: " ++ fmt ++ "\n", args);
    std.process.exit(1);
}

const Disc = struct {
    file: Io.File,
    io: Io,

    fn sector(self: Disc, lba: u32, out: *[user_len]u8) !void {
        const n = try self.file.readPositionalAll(self.io, out, @as(u64, lba) * raw_sector + user_off);
        if (n != user_len) return error.ShortRead;
    }
};

pub const DirEntry = struct { lba: u32, size: u32, name: []const u8 };

/// Lê um registro de diretório ISO9660; null = fim do setor (padding).
pub fn parseDirRecord(buf: []const u8) ?struct { entry: DirEntry, len: usize } {
    if (buf.len == 0 or buf[0] == 0) return null;
    const len = buf[0];
    if (len < 34 or len > buf.len) return null;
    const name_len = buf[32];
    if (33 + @as(usize, name_len) > len) return null;
    return .{
        .entry = .{
            .lba = std.mem.readInt(u32, buf[2..6], .little),
            .size = std.mem.readInt(u32, buf[10..14], .little),
            .name = buf[33 .. 33 + name_len],
        },
        .len = len,
    };
}

/// Compara "SLUS_006.79" com "SLUS_006.79;1" (ignora a versão).
pub fn nameMatches(iso_name: []const u8, want: []const u8) bool {
    const base = if (std.mem.indexOfScalar(u8, iso_name, ';')) |i| iso_name[0..i] else iso_name;
    return std.ascii.eqlIgnoreCase(base, want);
}

fn findInRoot(d: Disc, want: []const u8) !DirEntry {
    var buf: [user_len]u8 = undefined;
    try d.sector(16, &buf);
    if (!std.mem.eql(u8, buf[1..6], "CD001")) return error.NotIso9660;
    const root = parseDirRecord(buf[156..190]) orelse return error.BadRoot;
    var lba = root.entry.lba;
    var left: i64 = root.entry.size;
    while (left > 0) : ({
        lba += 1;
        left -= user_len;
    }) {
        try d.sector(lba, &buf);
        var off: usize = 0;
        while (parseDirRecord(buf[off..])) |r| : (off += r.len) {
            if (nameMatches(r.entry.name, want)) return r.entry;
        }
    }
    return error.FileNotFound;
}

/// Lista recursivamente a ISO9660 (LBA, tamanho, caminho).
fn listDir(d: Disc, lba0: u32, size: u32, prefix: []const u8, depth: u8) !void {
    if (depth > 8) return;
    var buf: [user_len]u8 = undefined;
    var lba = lba0;
    var left: i64 = size;
    while (left > 0) : ({
        lba += 1;
        left -= user_len;
    }) {
        try d.sector(lba, &buf);
        var off: usize = 0;
        while (parseDirRecord(buf[off..])) |r| : (off += r.len) {
            const name = r.entry.name;
            if (name.len == 1 and (name[0] == 0 or name[0] == 1)) continue; // . e ..
            const is_dir = (buf[off + 25] & 0x02) != 0;
            var pbuf: [256]u8 = undefined;
            const path = std.fmt.bufPrint(&pbuf, "{s}/{s}", .{ prefix, name }) catch continue;
            std.debug.print("{d:>8} {d:>10} {s}{s}\n", .{ r.entry.lba, r.entry.size, path, if (is_dir) "/" else "" });
            if (is_dir) try listDir(d, r.entry.lba, r.entry.size, path, depth + 1);
        }
    }
}

fn list(io: Io, bin: []const u8) !void {
    const f = try Io.Dir.cwd().openFile(io, bin, .{});
    defer f.close(io);
    const d = Disc{ .file = f, .io = io };
    var buf: [user_len]u8 = undefined;
    try d.sector(16, &buf);
    if (!std.mem.eql(u8, buf[1..6], "CD001")) return error.NotIso9660;
    const root = parseDirRecord(buf[156..190]) orelse return error.BadRoot;
    std.debug.print("{s:>8} {s:>10} caminho\n", .{ "LBA", "bytes" });
    try listDir(d, root.entry.lba, root.entry.size, "", 0);
}

fn verify(io: Io, path: []const u8) !bool {
    const f = try Io.Dir.cwd().openFile(io, path, .{});
    defer f.close(io);
    const size = try f.length(io);
    var h = std.crypto.hash.Sha1.init(.{});
    var buf: [1 << 20]u8 = undefined;
    var pos: u64 = 0;
    while (pos < size) {
        const n = try f.readPositionalAll(io, &buf, pos);
        if (n == 0) break;
        h.update(buf[0..n]);
        pos += n;
    }
    var digest: [20]u8 = undefined;
    h.final(&digest);
    const hex = std.fmt.bytesToHex(digest, .lower);
    const ok = size == known_size and std.mem.eql(u8, &hex, known_sha1);
    std.debug.print("{s}\n  tamanho {d}  sha1 {s}\n  {s}\n", .{
        path, size, &hex, if (ok) "✅ dump confere (SLUS-00679 Redump)" else "❌ dump diferente do esperado",
    });
    return ok;
}

fn extract(io: Io, bin: []const u8, out_dir: []const u8) !void {
    const f = try Io.Dir.cwd().openFile(io, bin, .{});
    defer f.close(io);
    const d = Disc{ .file = f, .io = io };
    const e = try findInRoot(d, boot_exe);

    try Io.Dir.cwd().createDirPath(io, out_dir);
    var dir = try Io.Dir.cwd().openDir(io, out_dir, .{});
    defer dir.close(io);
    const out = try dir.createFile(io, boot_exe, .{});
    defer out.close(io);

    var buf: [user_len]u8 = undefined;
    var left: u32 = e.size;
    var lba = e.lba;
    while (left > 0) : (lba += 1) {
        try d.sector(lba, &buf);
        const n = @min(left, user_len);
        try out.writeStreamingAll(io, buf[0..n]);
        left -= n;
    }
    std.debug.print("📀 {s}/{s} extraído ({d} bytes, LBA {d})\n", .{ out_dir, boot_exe, e.size, e.lba });
}

/// Primeiro `FILE "..."` do .cue, resolvido relativo ao diretório do .cue.
fn binFromCue(gpa: std.mem.Allocator, io: Io, cue: []const u8) ![]u8 {
    const text = try Io.Dir.cwd().readFileAlloc(io, cue, gpa, .limited(1 << 16));
    defer gpa.free(text);
    const k = std.mem.indexOf(u8, text, "FILE \"") orelse return error.BadCue;
    const rest = text[k + 6 ..];
    const end = std.mem.indexOfScalar(u8, rest, '"') orelse return error.BadCue;
    const dirname = std.fs.path.dirname(cue) orelse ".";
    return std.fs.path.join(gpa, &.{ dirname, rest[0..end] });
}

pub fn main(init: std.process.Init) !void {
    const io = init.io;
    const gpa = init.gpa;
    const args = try init.minimal.args.toSlice(init.arena.allocator());
    if (args.len < 3) die("uso: tgtool verify <bin> | list <bin> | extract <bin> <outdir> | setup <cue>", .{});
    const cmd = args[1];
    if (std.mem.eql(u8, cmd, "verify")) {
        if (!try verify(io, args[2])) std.process.exit(2);
    } else if (std.mem.eql(u8, cmd, "list")) {
        try list(io, args[2]);
    } else if (std.mem.eql(u8, cmd, "extract")) {
        if (args.len < 4) die("uso: tgtool extract <bin> <outdir>", .{});
        try extract(io, args[2], args[3]);
    } else if (std.mem.eql(u8, cmd, "setup")) {
        const bin = try binFromCue(gpa, io, args[2]);
        defer gpa.free(bin);
        if (!try verify(io, bin)) std.debug.print("⚠️  seguindo mesmo assim; o recomp foi validado só com o dump Redump\n", .{});
        try extract(io, bin, "disc");
        std.debug.print("👉 coloque em game.toml:  disc = \"{s}\"\n", .{args[2]});
    } else die("comando desconhecido: {s}", .{cmd});
}

test "parseDirRecord + nameMatches" {
    var rec: [48]u8 = @splat(0);
    rec[0] = 46;
    std.mem.writeInt(u32, rec[2..6], 23, .little);
    std.mem.writeInt(u32, rec[10..14], 1022 * 1024, .little);
    rec[32] = 13;
    @memcpy(rec[33..46], "SLUS_006.79;1");
    const r = parseDirRecord(&rec).?;
    try std.testing.expectEqual(@as(u32, 23), r.entry.lba);
    try std.testing.expectEqual(@as(usize, 46), r.len);
    try std.testing.expect(nameMatches(r.entry.name, boot_exe));
    try std.testing.expect(!nameMatches("SYSTEM.CNF;1", boot_exe));
    try std.testing.expect(parseDirRecord(&[_]u8{0}) == null);
}
