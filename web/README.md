# 🌐 Trap Gunner Web

PS1 core written from scratch in **Zig** and compiled to **WebAssembly**, MIT-licensed
(see [docs/WASM_STRATEGY.md](../docs/WASM_STRATEGY.md)). The game runs in the
player's browser from **their own disc**; no game data is published.

| Part | Status |
|---|---|
| R3000A CPU (reference interpreter), COP0, IRQ, DMA, timers | ✅ |
| GPU (software rasterizer, 15/24-bit), GTE, CD-ROM, MDEC, controller | ✅ |
| Boot via OpenBIOS (MIT) → title → menu → Story mission 1 | ✅ (native and browser, 60 fps on desktop) |
| Browser: disc picker, OPFS cache, Gamepad API + keyboard, Web Worker | ✅ |
| Intro FMVs | ⏭️ skipped (guarded patch; full playback still WIP) |
| SPU (audio) | ❌ not yet |
| MIPS → wasm recompiler | 🚧 next phase |
| WebRTC netplay | 🚧 |

## Build

```bash
cd web
zig build test            # tests
zig build wasm            # www/psxcore.wasm
zig build -Doptimize=ReleaseFast   # native harness (tests without a browser)
./zig-out/bin/psxweb-native www/openbios.bin "Trap Gunner.bin" SLUS_006.79 900 out.ppm
```

Serve `www/` over HTTP and open it in the browser. GitHub Pages publishes it automatically
(`.github/workflows/pages.yml`).

`www/openbios.bin` is OpenBIOS (PCSX-Redux project, MIT; see `OpenBIOS.LICENSE`).
