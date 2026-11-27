// Plays the PCM (i16 stereo) the core generates, using a ring buffer.
class PsxAudio extends AudioWorkletProcessor {
  constructor() {
    super();
    this.buf = new Float32Array(44100 * 2); // ~1 s of stereo
    this.w = 0; this.r = 0;
    this.port.onmessage = (e) => {
      const pcm = e.data;
      for (let i = 0; i < pcm.length; i++) { this.buf[this.w] = pcm[i] / 32768; this.w = (this.w + 1) % this.buf.length; }
      // if latency builds up (> ~150 ms), drop the excess
      const avail = (this.w - this.r + this.buf.length) % this.buf.length;
      if (avail > 44100 * 2 * 0.15) this.r = (this.w - Math.floor(44100 * 2 * 0.05) + this.buf.length) % this.buf.length & ~1;
    };
  }
  process(_in, outputs) {
    const [l, r] = outputs[0];
    for (let i = 0; i < l.length; i++) {
      if (this.r !== this.w) {
        l[i] = this.buf[this.r]; r[i] = this.buf[this.r + 1];
        this.r = (this.r + 2) % this.buf.length;
      } else { l[i] = 0; r[i] = 0; }
    }
    return true;
  }
}
registerProcessor('psx-audio', PsxAudio);
