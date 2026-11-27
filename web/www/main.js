// Interface: escolhe o disco, cuida da entrada (gamepad + teclado) e conversa com o worker.
const $ = (id) => document.getElementById(id);
const status = (t) => { $('status').textContent = t; };
let worker = null;

// Botões PS1 (ativo baixo no núcleo): bit -> nome
const BTN = { select: 0, start: 3, up: 4, right: 5, down: 6, left: 7, l2: 8, r2: 9, l1: 10, r1: 11, tri: 12, circle: 13, cross: 14, square: 15 };
const keys = { ArrowUp: 'up', ArrowDown: 'down', ArrowLeft: 'left', ArrowRight: 'right', KeyX: 'cross', KeyZ: 'circle',
  KeyS: 'square', KeyA: 'tri', Enter: 'start', ShiftLeft: 'select', ShiftRight: 'select', KeyQ: 'l1', KeyW: 'r1', KeyE: 'l2', KeyR: 'r2' };
// Cada toque dura pelo menos 100 ms (toques rápidos não se perdem entre quadros).
const held = new Map(); // nome -> instante mínimo de soltura (Infinity enquanto pressionado)
addEventListener('keydown', (e) => { if (keys[e.code]) { held.set(keys[e.code], Infinity); e.preventDefault(); } });
addEventListener('keyup', (e) => { if (keys[e.code]) held.set(keys[e.code], performance.now() + 100); });

// Mapeamento "standard" da Gamepad API
const PADMAP = { 0: 'cross', 1: 'circle', 2: 'square', 3: 'tri', 4: 'l1', 5: 'r1', 6: 'l2', 7: 'r2', 8: 'select', 9: 'start',
  12: 'up', 13: 'down', 14: 'left', 15: 'right' };
function padMask(gp) {
  let m = 0;
  if (!gp) return m;
  gp.buttons.forEach((b, i) => { if (b.pressed && PADMAP[i]) m |= 1 << BTN[PADMAP[i]]; });
  const [x, y] = gp.axes;
  if (x < -0.5) m |= 1 << BTN.left; if (x > 0.5) m |= 1 << BTN.right;
  if (y < -0.5) m |= 1 << BTN.up; if (y > 0.5) m |= 1 << BTN.down;
  return m;
}
function inputLoop() {
  const pads = navigator.getGamepads ? [...navigator.getGamepads()].filter(Boolean) : [];
  let p1 = padMask(pads[0]);
  const now = performance.now();
  for (const [k, until] of held) { if (until <= now) held.delete(k); else p1 |= 1 << BTN[k]; }
  const p2 = padMask(pads[1]);
  worker?.postMessage({ type: 'input', p1: ~p1 & 0xFFFF, p2: ~p2 & 0xFFFF, p2c: pads.length > 1 });
  requestAnimationFrame(inputLoop);
}

async function opfsDisc() {
  try { const root = await navigator.storage.getDirectory(); return await root.getFileHandle('disc.bin'); } catch { return null; }
}

// ---- audio: AudioWorklet with a ring buffer, 44.1 kHz stereo ----
let audioNode = null, ac = null, muted = false;
// Browsers only allow audio after a user gesture: create/resume the context on every click or key.
const unlock = () => { if (!ac) ac = new AudioContext({ sampleRate: 44100, latencyHint: 'interactive' }); if (!muted && ac.state !== 'running') ac.resume(); };
addEventListener('pointerdown', unlock, true);
addEventListener('keydown', unlock, true);
async function initAudio() {
  try {
    unlock();
    await ac.audioWorklet.addModule('audio-worklet.js');
    audioNode = new AudioWorkletNode(ac, 'psx-audio', { outputChannelCount: [2] });
    audioNode.connect(ac.destination);
    await ac.resume();
    $('mute').onclick = () => {
      muted = !muted;
      if (muted) { ac.suspend(); $('mute').textContent = '🔇 Som'; }
      else { ac.resume(); $('mute').textContent = '🔊 Som'; }
    };
  } catch (e) { console.warn('audio indisponível', e); }
}

function start(source, net = null) {
  initAudio();
  $('setup').querySelectorAll('button,label.btn,input,select').forEach((b) => { if (!['mute', 'fps', 'copylink'].includes(b.id)) b.setAttribute('disabled', ''); });
  const canvas = $('screen').transferControlToOffscreen();
  worker = new Worker('worker.js');
  worker.onmessage = (e) => {
    const m = e.data;
    if (m.type === 'status') status(m.text);
    if (m.type === 'error') status('Erro: ' + m.text);
    if (m.type === 'audio' && audioNode) audioNode.port.postMessage(m.pcm, [m.pcm.buffer]);
    if (m.type === 'local' && chan?.readyState === 'open') chan.send(JSON.stringify({ t: 'in', f: m.f, p: m.p }));
    if (m.type === 'hash' && chan?.readyState === 'open') chan.send(JSON.stringify({ t: 'hash', f: m.f, h: m.h }));
  };
  const fps = net?.fps ?? +$('fps').value;
  worker.postMessage({ type: 'start', canvas, source, skipFmv: net ? net.skipFmv : $('skipfmv').checked, fps, net: net && { slot: net.slot, delay: 4 } }, [canvas]);
  if (net) $('fps').setAttribute('disabled', '');
  requestAnimationFrame(inputLoop);
}

// ---- disc chosen: show the modes ----
let source = null;
const roomFromUrl = () => (location.hash.match(/^#\/sala\/([A-Z0-9]{6})$/i) || [])[1]?.toUpperCase();
const roomLink = (code) => `${location.origin}${location.pathname}#/sala/${code}`;
function discReady(s) {
  source = s;
  $('modes').hidden = false;
  const code = roomFromUrl();
  if (code) { $('code').value = code; status(`Disco pronto. Clique em "Entrar na sala" para entrar em ${code}.`); $('join').focus(); }
  else status('Disco pronto. Jogue sozinho ou online.');
}
function showRoom() {
  const code = roomFromUrl();
  if (code) { $('code').value = code; if (!source) status(`Convite para a sala ${code}: escolha seu disco para entrar.`); }
}
addEventListener('hashchange', showRoom);
showRoom();
$('copylink').onclick = async () => {
  const link = roomLink($('code').value);
  try { await navigator.clipboard.writeText(link); status('Link copiado: ' + link); } catch { prompt('Copie o link:', link); }
};
$('solo').onclick = () => start(source);

// ---- online play: WebRTC + signaling at /api/room/CODE ----
let pc = null, chan = null;
const ICE = [{ urls: 'stun:stun.cloudflare.com:3478' }, { urls: 'stun:stun.l.google.com:19302' }];
const sleep = (ms) => new Promise((r) => setTimeout(r, ms));
const newCode = () => Array.from(crypto.getRandomValues(new Uint8Array(6)), (b) => 'ABCDEFGHJKLMNPQRSTUVWXYZ23456789'[b % 32]).join('');
async function gathered(pc) {
  if (pc.iceGatheringState === 'complete') return;
  await new Promise((r) => { pc.addEventListener('icegatheringstatechange', () => pc.iceGatheringState === 'complete' && r()); setTimeout(r, 4000); });
}
async function api(code, method, body) {
  const r = await fetch(`/api/room/${code}` + (method === 'GET' ? `?want=${body}` : ''), method === 'GET' ? {} : { method, headers: { 'content-type': 'application/json' }, body: JSON.stringify(body) });
  return r.ok ? r.json() : null;
}
async function poll(code, want) {
  for (let i = 0; i < 300; i++) { const r = await api(code, 'GET', want); if (r?.sdp) return r.sdp; await sleep(1000); }
  throw new Error('tempo esgotado esperando o outro jogador');
}
function wire(slot, onOpen) {
  chan.onopen = onOpen;
  chan.onmessage = (e) => {
    const m = JSON.parse(e.data);
    if (m.t === 'start') start(source, { slot, fps: m.fps, skipFmv: m.skipFmv });
    if (m.t === 'in') worker?.postMessage({ type: 'remote', f: m.f, p: m.p });
    if (m.t === 'hash') worker?.postMessage({ type: 'rhash', f: m.f, h: m.h });
  };
  chan.onclose = () => status('Conexão com o outro jogador encerrada.');
}
$('host').onclick = async () => {
  try {
    const code = newCode();
    pc = new RTCPeerConnection({ iceServers: ICE });
    chan = pc.createDataChannel('inputs', { ordered: true });
    wire(0, () => {
      status('Conectado! Iniciando…');
      const cfg = { t: 'start', fps: +$('fps').value, skipFmv: $('skipfmv').checked };
      chan.send(JSON.stringify(cfg));
      start(source, { slot: 0, fps: cfg.fps, skipFmv: cfg.skipFmv });
    });
    await pc.setLocalDescription(await pc.createOffer());
    await gathered(pc);
    if (!(await api(code, 'POST', { kind: 'offer', sdp: pc.localDescription }))) throw new Error('não foi possível criar a sala');
    $('code').value = code;
    history.replaceState(null, '', '#/sala/' + code);
    $('copylink').hidden = false;
    status(`Sala criada: mande o link ${roomLink(code)} para o outro jogador. Aguardando…`);
    await pc.setRemoteDescription(await poll(code, 'answer'));
  } catch (e) { status('Online: ' + e.message); }
};
$('join').onclick = async () => {
  try {
    const code = $('code').value.trim().toUpperCase();
    if (/^[A-Z0-9]{6}$/.test(code)) history.replaceState(null, '', '#/sala/' + code);
    if (!/^[A-Z0-9]{6}$/.test(code)) return status('Digite o código de 6 caracteres.');
    status('Procurando a sala…');
    pc = new RTCPeerConnection({ iceServers: ICE });
    pc.ondatachannel = (e) => { chan = e.channel; wire(1, () => status('Conectado! Aguardando o jogador 1 iniciar…')); };
    await pc.setRemoteDescription(await poll(code, 'offer'));
    await pc.setLocalDescription(await pc.createAnswer());
    await gathered(pc);
    await api(code, 'POST', { kind: 'answer', sdp: pc.localDescription });
    status('Conectando ao jogador 1…');
  } catch (e) { status('Online: ' + e.message); }
};

$('disc').addEventListener('change', async (e) => {
  const file = e.target.files[0];
  if (!file) return;
  discReady({ kind: 'file', file });
});
// Quadros desenhados por segundo (a velocidade do jogo não muda); lembrado entre visitas.
try { const f = localStorage.getItem('tg.fps'); if (f === '30' || f === '60') $('fps').value = f; } catch {}
$('fps').addEventListener('change', () => {
  try { localStorage.setItem('tg.fps', $('fps').value); } catch {}
  worker?.postMessage({ type: 'fps', fps: +$('fps').value });
});
$('cached').addEventListener('click', () => discReady({ kind: 'opfs' }));
(async () => { if (await opfsDisc()) $('cached').hidden = false; })();

// Teste local: ?disc=URL lê o disco por HTTP Range (servidor local).
const qs = new URLSearchParams(location.search);
if (qs.get('disc')) discReady({ kind: 'url', url: qs.get('disc') });
if (qs.get('autostart')) start(source);

if ('serviceWorker' in navigator && location.protocol === 'https:') navigator.serviceWorker.register('sw.js');
