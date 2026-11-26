# 🔫 TrapGunnerRecomp

Recompilação estática (*static recomp*) de **Trap Gunner – Countdown to Oblivion**
(PlayStation, Atlus 1998, **SLUS-00679**) para executável nativo, feita sobre o
framework [psxrecomp](https://github.com/mstan/psxrecomp).

O código MIPS R3000A do jogo é traduzido para C e compilado junto com um
runtime de hardware do PS1 (GPU/OpenGL, SPU, CD-ROM, GTE, BIOS OpenBIOS
inclusa). Overlays carregados do disco em tempo de execução são capturados e
compilados em segundo plano; o que ainda não for nativo cai num interpretador.

> ⚠️ **Este repositório não contém nada do jogo.** Nada de disco, BIOS ou do C
> recompilado (que é derivado direto do executável da Atlus). Você gera tudo
> localmente a partir do **seu próprio dump**.

## 📊 Estado

| Parte | Status |
|---|---|
| Boot, logos e FMV de abertura | ✅ |
| Tela de título e menus | ✅ |
| Modo Story: briefing e primeira missão (tela dividida, HUD, timer) | ✅ |
| Movimento do jogador | ✅ |
| VS MAN (2 jogadores): seleção, fase e controles independentes | ✅ |
| Overlays | ✅ 100% nativo: o jogo não tem overlays (veja [docs/AOT.md](docs/AOT.md)) |
| Mods (`.psxmod`) — exemplo *Infinite Match Timer* | ✅ testado |
| Netplay (rollback, LAN/Direct IP e lobby online) | ✅ 2 instâncias sincronizadas (macOS) |
| RecompLauncher (`recomplauncher.json`) | ✅ valida no schema oficial |
| Campanha completa, áudio e saves | 🔍 ainda não validados |

Testado no macOS (Apple Silicon). O psxrecomp também suporta Windows e Linux.

## 🧰 Requisitos

- Git, Python 3, CMake ≥ 3.20, Ninja, clang/gcc (`xcode-select --install` e
  `brew install cmake ninja python zig`)
- [Zig](https://ziglang.org) 0.17 (para o `tgtool`)
- Dump **Redump** de Trap Gunner (USA), um único `.bin` + `.cue`:
  - SHA-1 `258d840cc7cbb8900d76fd7d1ca499b4085ad6e1`, 708410640 bytes

## 🚀 Build

```bash
git clone --recursive https://github.com/thomasgroch/TrapGunnerRecomp
cd TrapGunnerRecomp
mkdir -p isos && cp "/caminho/Trap Gunner."{bin,cue} isos/
./scripts/build.sh "isos/Trap Gunner.cue"
./build-release/TrapGunner_Recompiled
```

O `scripts/build.sh`:
1. confere o dump e extrai o `SLUS_006.79` (`tgtool`, em Zig);
2. compila os emissores do psxrecomp;
3. gera o C do jogo em `generated/` (fica fora do Git);
4. compila o executável nativo em `build-release/`.

## ⚡ tgtool (Zig)

Ferramenta pequena e sem dependências, em `tools/tgtool`:

```bash
cd tools/tgtool && zig build -Doptimize=ReleaseFast && zig build test
./zig-out/bin/tgtool list    "Trap Gunner.bin"      # lista os arquivos do disco
./zig-out/bin/tgtool verify  "Trap Gunner.bin"      # confere o SHA-1 do Redump
./zig-out/bin/tgtool extract "Trap Gunner.bin" out  # lê a ISO9660 (MODE2/2352) e extrai o EXE
./zig-out/bin/tgtool setup   "Trap Gunner.cue"      # verify + extract em disc/
```

## 🧩 Mods

O jogo usa o sistema de mods do psxrecomp (`.psxmod` = ZIP + `manifest.toml`).

- **Embutidos:** `mods/preloaded/packages/<id>/<versão>/` vêm no build, desligados por
  padrão. Para ligar, use a aba Mods do launcher.
- **Do jogador:** arquivos `.psxmod` em `mods/installed/` (instale pelo launcher).
- **Exemplo incluído:** `trapgunner.gameplay.infinite-timer`. Ele para o relógio da
  partida trocando os quatro `addiu rX, rX, -1` que decrementam o word `0x801093D8`.
  Gere o `.psxmod` com:
  ```bash
  python3 psxrecomp/tools/psxmod_pack.py \
    mods/preloaded/packages/trapgunner.gameplay.infinite-timer/1.0.0 \
    dist/trapgunner-infinite-timer-1.0.0.psxmod
  ```
- Formato completo: `psxrecomp/psxmod.md` e `psxrecomp/docs/MOD_PACKAGES.md`.
- No netplay, os mods de gameplay são desligados (a sessão é *vanilla*) para os dois
  lados ficarem determinísticos.

## 🌐 Online (netplay)

Rollback via [recomp-net](https://github.com/RetroPortingToolKit/recomp-net). O launcher
recomp-ui (botão **NETPLAY**) oferece:

- **Online:** lobby `ws://netplay.retcomm.net:8765` (ICE/TURN, SFU de reserva)
- **LAN / Direct IP:** UDP na porta 7777

Os dois jogadores precisam do **mesmo build** e do **mesmo dump**: o framework compara
o executável, a BIOS, o disco e a config. O catálogo de host do título fica em
`src/trapgunner_netplay_host.c` (perfil `trapgunner-vanilla`, arm64 e x64).

> 🍎 **macOS:** o psxrecomp upstream só identifica o executável em Windows e Linux.
> `patches/psxrecomp-0001-macos-executable-identity.patch` adiciona o macOS
> (`proc_pidpath`). O `scripts/build.sh` aplica o patch.

Teste por linha de comando, sem launcher:
```bash
PSX_NETPLAY=1 PSX_NET_SLOT=0 PSX_NET_SLOTS=2 PSX_NET_BIND=0.0.0.0:7777 \
  PSX_NET_PEER=<ip-do-amigo>:7777 PSX_NET_MODE=rollback \
  ./build-release/TrapGunner_Recompiled --game game.toml
# o amigo usa PSX_NET_SLOT=1
```

## 🚀 RecompLauncher

O [`recomplauncher.json`](recomplauncher.json) (formato 1, validado no CI contra
<https://recomplauncher.com/schema/recomplauncher.json>) declara:

- **entrada `game`:** o `.cue`/`.bin` do jogador, conferido pelo `SLUS_006.79` na ISO9660,
  pelo serial `SLUS-00679` e pelo dump Redump (CRC32 `f6f00f7c`);
- **início:** `TrapGunner_Recompiled --game game.toml --disc {input:game}`;
- **saves, logs e ações** (abrir mods, limpar cache de overlay).

O `scripts/package_release.sh` coloca o manifesto na raiz do zip, ao lado do
executável. Os nomes dos assets (`trapgunner-<versão>-windows-x64.zip` etc.) seguem
o padrão que o launcher reconhece.

## 🧪 Teste automatizado (headless)

```bash
PSX_DEBUG_SERVER=1 ./build-release/TrapGunner_Recompiled \
  --no-launcher --headless --game game.toml --debug-port 4600
# {"cmd":"screenshot_file","path":"shot.png"} e {"cmd":"press","buttons":<máscara>}
# por TCP; a máscara é ativa em nível baixo (0xFFFF = nada pressionado).
# Controle 2: {"cmd":"press","port":2,"connected":1,...}. O VS MAN só
# aparece no menu quando há um controle na porta 2.
```

## 🗺️ Próximos passos

- Rotular funções em `symbols.toml` (`tools/sync_symbols.py`)
- Validar a campanha, o áudio e o memory card; widescreen

## 📜 Licença

O código deste repositório (tgtool, scripts, config) é **MIT**. O submódulo
`psxrecomp/` tem licença própria (PolyForm Noncommercial 1.0.0). *Trap Gunner*
é marca da Atlus; este projeto não é afiliado à Atlus nem à Sony.
