// Worker: carrega o núcleo wasm, lê o disco do jogador de forma síncrona e desenha.
let mem, core, readSector, ctx, img;
let pad1 = 0xFFFF, pad2 = 0xFFFF, pad2c = false;
// Online play (lockstep): `net` = { slot: 0|1, delay } ; inputs per frame.
let net = null, frameNo = 0;
const localIn = new Map(), remoteIn = new Map();
const post = (type, text) => postMessage({ type, text });

// --- fontes de disco (todas síncronas, só possíveis dentro de um worker) ---
function fileReader(file) {
  const r = new FileReaderSync();
  return (lba, out) => {
    const off = lba * 2352;
    if (off + 2352 > file.size) return false;
    out.set(new Uint8Array(r.readAsArrayBuffer(file.slice(off, off + 2352))));
    return true;
  };
}
function opfsReader(handle) {
  const size = handle.getSize();
  return (lba, out) => {
    const off = lba * 2352;
    if (off + 2352 > size) return false;
    return handle.read(out, { at: off }) === 2352;
  };
}
function urlReader(url) {
  return (lba, out) => {
    const x = new XMLHttpRequest();
    x.open('GET', url, false);
    x.responseType = 'arraybuffer';
    x.setRequestHeader('Range', `bytes=${lba * 2352}-${lba * 2352 + 2351}`);
    x.send();
    if (x.status !== 206 && x.status !== 200) return false;
    out.set(new Uint8Array(x.response).subarray(0, 2352));
    return true;
  };
}

// Copia o disco para o OPFS (cache local) para as próximas visitas.
async function cacheToOpfs(file) {
  try {
    const root = await navigator.storage.getDirectory();
    const h = await root.getFileHandle('disc.bin', { create: true });
    const sync = await h.createSyncAccessHandle();
    sync.truncate(0);
    const CH = 2352 * 512;
    const r = new FileReaderSync();
    for (let off = 0; off < file.size; off += CH) {
      sync.write(new Uint8Array(r.readAsArrayBuffer(file.slice(off, off + CH))), { at: off });
      if ((off / CH) % 50 === 0) post('status', `Salvando disco no navegador… ${Math.round((100 * off) / file.size)}%`);
    }
    sync.flush();
    return sync;
  } catch (e) {
    post('status', 'Cache local indisponível; usando o arquivo direto.');
    return null;
  }
}

onmessage = async (e) => {
  const m = e.data;
  if (m.type === 'input') { pad1 = m.p1; pad2 = m.p2; pad2c = m.p2c; return; }
  if (m.type === 'fps') { drawEvery = m.fps >= 60 ? 1 : 2; return; }
  if (m.type === 'remote') { remoteIn.set(m.f, m.p); return; }
  if (m.type === 'rhash') { checkHash(m.f, m.h); return; }
  if (m.type !== 'start') return;
  if (m.fps) drawEvery = m.fps >= 60 ? 1 : 2;
  if (m.net) net = m.net;
  try {
    ctx = m.canvas.getContext('2d');
    const src = m.source;
    if (src.kind === 'file') {
      const sync = await cacheToOpfs(src.file);
      readSector = sync ? opfsReader(sync) : fileReader(src.file);
    } else if (src.kind === 'opfs') {
      const root = await navigator.storage.getDirectory();
      const h = await root.getFileHandle('disc.bin');
      readSector = opfsReader(await h.createSyncAccessHandle());
    } else {
      readSector = urlReader(src.url);
    }
    post('status', 'Carregando núcleo…');
    const { instance } = await WebAssembly.instantiateStreaming(fetch('psxcore.wasm'), {
      env: {
        js_read_sector: (lba, ptr) => readSector(lba, new Uint8Array(mem.buffer, ptr, 2352)) ? 1 : 0,
        js_log: (ptr, len) => console.log(new TextDecoder().decode(new Uint8Array(mem.buffer, ptr, len))),
      },
    });
    core = instance.exports;
    mem = core.memory;
    const bios = new Uint8Array(await (await fetch('openbios.bin')).arrayBuffer());
    new Uint8Array(mem.buffer, core.tg_bios_ptr(), bios.length).set(bios);
    post('status', 'Iniciando (BIOS → jogo)…');
    const rc = core.tg_init(bios.length, m.skipFmv ? 1 : 0);
    if (rc !== 0) throw new Error(['', 'SLUS_006.79 não encontrado: confira o dump', 'BIOS não iniciou', 'EXE inválido'][rc]);
    post('status', 'Rodando. 🎮');
    loop();
  } catch (err) {
    post('error', err.message || String(err));
  }
};

let last = 0, acc = 0, frames = 0, fpsT = performance.now(), stalled = 0;
const myHash = new Map(), theirHash = new Map();
function checkHash(f, h) {
  if (h !== null) theirHash.set(f, h);
  if (myHash.has(f) && theirHash.has(f)) {
    if (myHash.get(f) !== theirHash.get(f)) post('status', `⚠️ Dessincronizado no quadro ${f}: os jogos divergiram.`);
    myHash.delete(f); theirHash.delete(f);
  }
}
// Velocidade fixa: NTSC = 59,94 quadros/s, independente da taxa da tela.
const FRAME_MS = 1000 / 59.94;
let drawEvery = 1;
function loop(t = performance.now()) {
  acc += Math.min(100, t - (last || t));
  last = t;
  let steps = 0;
  while (acc >= FRAME_MS && steps < 4) {
    let wh;
    if (net) {
      // send my input for frame (frameNo + delay); run frameNo when both are in
      const ahead = frameNo + net.delay;
      if (!localIn.has(ahead)) { localIn.set(ahead, pad1); postMessage({ type: 'local', f: ahead, p: pad1 }); }
      const mine = frameNo < net.delay ? 0xFFFF : localIn.get(frameNo);
      const theirs = frameNo < net.delay ? 0xFFFF : remoteIn.get(frameNo);
      if (theirs === undefined) { stalled++; break; } // waiting for the other player
      stalled = 0;
      const p1 = net.slot === 0 ? mine : theirs, p2 = net.slot === 0 ? theirs : mine;
      wh = core.tg_frame(p1, p2, 1);
      localIn.delete(frameNo); remoteIn.delete(frameNo);
      if (frameNo % 300 === 0) { const h = core.tg_hash() >>> 0; myHash.set(frameNo, h); postMessage({ type: 'hash', f: frameNo, h }); checkHash(frameNo, null); }
      frameNo++;
    } else {
      wh = core.tg_frame(pad1, pad2, pad2c ? 1 : 0);
    }
    const na = core.tg_audio();
    if (na) {
      const pcm = new Int16Array(mem.buffer, core.tg_audio_ptr(), na).slice();
      postMessage({ type: 'audio', pcm }, [pcm.buffer]);
    }
    acc -= FRAME_MS;
    steps++;
    frames++;
    if (steps === 1 && frames % drawEvery === 0) draw(wh & 0xFFFF, wh >>> 16);
  }
  if (t - fpsT > 2000) {
    const fps = Math.round((frames * 1000) / (t - fpsT));
    post('status', net ? `Online (P${net.slot + 1}) · ${fps} fps${stalled > 30 ? ' · aguardando o outro jogador…' : ''}` : `Rodando · ${fps} fps`);
    frames = 0; fpsT = t;
  }
  (self.requestAnimationFrame || ((f) => setTimeout(() => f(performance.now()), 4)))(loop);
}
function draw(w, h) {
  if (!img || img.width !== w || img.height !== h) {
    img = new ImageData(w, h);
    ctx.canvas.width = w;
    ctx.canvas.height = h;
  }
  img.data.set(new Uint8Array(mem.buffer, core.tg_fb_ptr(), w * h * 4));
  ctx.putImageData(img, 0, 0);
}
