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
let audioNode = null;
async function initAudio() {
  try {
    const ac = new AudioContext({ sampleRate: 44100, latencyHint: 'interactive' });
    await ac.audioWorklet.addModule('audio-worklet.js');
    audioNode = new AudioWorkletNode(ac, 'psx-audio', { outputChannelCount: [2] });
    audioNode.connect(ac.destination);
    await ac.resume();
    $('mute').onclick = () => {
      if (ac.state === 'running') { ac.suspend(); $('mute').textContent = '🔇 Som'; }
      else { ac.resume(); $('mute').textContent = '🔊 Som'; }
    };
  } catch (e) { console.warn('audio indisponível', e); }
}

function start(source) {
  initAudio();
  $('setup').querySelectorAll('button,label.btn').forEach((b) => b.setAttribute('disabled', ''));
  const canvas = $('screen').transferControlToOffscreen();
  worker = new Worker('worker.js');
  worker.onmessage = (e) => {
    const m = e.data;
    if (m.type === 'status') status(m.text);
    if (m.type === 'error') status('Erro: ' + m.text);
    if (m.type === 'audio' && audioNode) audioNode.port.postMessage(m.pcm, [m.pcm.buffer]);
  };
  worker.postMessage({ type: 'start', canvas, source, skipFmv: $('skipfmv').checked, fps: +$('fps').value }, [canvas]);
  requestAnimationFrame(inputLoop);
}

$('disc').addEventListener('change', async (e) => {
  const file = e.target.files[0];
  if (!file) return;
  start({ kind: 'file', file });
});
// FPS alvo (ajusta a velocidade do jogo); lembrado entre visitas.
try { const f = localStorage.getItem('tg.fps'); if (f) $('fps').value = f; } catch {}
$('fps').addEventListener('change', () => {
  try { localStorage.setItem('tg.fps', $('fps').value); } catch {}
  worker?.postMessage({ type: 'fps', fps: +$('fps').value });
});
$('cached').addEventListener('click', () => start({ kind: 'opfs' }));
(async () => { if (await opfsDisc()) $('cached').hidden = false; })();

// Teste local: ?disc=URL lê o disco por HTTP Range (servidor local).
const qs = new URLSearchParams(location.search);
if (qs.get('disc')) start({ kind: 'url', url: qs.get('disc') });

if ('serviceWorker' in navigator && location.protocol === 'https:') navigator.serviceWorker.register('sw.js');
