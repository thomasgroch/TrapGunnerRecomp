# 🌐 Estratégia WebAssembly

## 1. Objetivo
1. Trap Gunner rodando no navegador: Android, PC, iOS.
2. Nenhum código da Atlus publicado; tudo é gerado no aparelho do jogador.
3. Stack 100% MIT, sem depender do psxrecomp.
4. Online via WebRTC.

## 2. Estratégia
1. Jogador abre a página e escolhe o `.cue`/`.bin`.
2. `tgtool` (wasm) verifica o dump e extrai `SLUS_006.79`.
3. Recompilador Zig (wasm) traduz MIPS em módulo `.wasm`.
4. `WebAssembly.compile()` gera código nativo; o navegador é o compilador.
5. Runtime PS1 (wasm) executa: GPU, SPU, CD, GTE, pad.
6. Resultado vai para cache (OPFS); próximas aberturas são instantâneas.
7. Netplay: rollback sobre WebRTC.

## 3. Fases
1. **PoC:** EXE → `.wasm`, boot até escrever na VRAM.
2. **Vídeo:** GPU em WebGL2; título e menus.
3. **Gameplay:** GTE, pad (Gamepad API, touch), timers.
4. **Mídia:** SPU (WebAudio), CD-XA, FMV (MDEC).
5. **Validação:** comparação quadro a quadro com o build psxrecomp.
6. **Online:** rollback via WebRTC.
7. **Entrega:** PWA instalável; mods.

## 4. Tooling
1. Zig (recompilador, runtime, `tgtool`)
2. WebAssembly
3. WebGL2
4. WebAudio
5. Gamepad API
6. WebRTC
7. OPFS / IndexedDB
8. PWA (Service Worker)
9. OpenBIOS
10. psxrecomp (gabarito de validação)
11. GitHub Actions + GitHub Pages
