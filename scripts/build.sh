#!/usr/bin/env bash
# Build completo do TrapGunnerRecomp a partir do SEU disco.
#   ./scripts/build.sh "/caminho/Trap Gunner.cue"
set -euo pipefail
CUE="${1:?uso: scripts/build.sh <Trap Gunner.cue>}"
cd "$(dirname "$0")/.."

echo "🔄 submódulos";        git submodule update --init --recursive
echo "⚡ tgtool (Zig)";      (cd tools/tgtool && zig build -Doptimize=ReleaseFast)
echo "📀 verificando disco"; ./tools/tgtool/zig-out/bin/tgtool setup "$CUE"
echo "🛠️  emissores";         bash psxrecomp/tools/ci/build_emitters.sh
echo "🧬 gerando C";         python3 psxrecomp/psxrecomp_cli.py generate \
                                --config game.toml --project-root . --disc "$CUE"
echo "🔨 compilando";        python3 psxrecomp/psxrecomp_cli.py rebuild \
                                --config game.toml --project-root . --build-dir build-release --no-pgo
echo "✅ pronto: build-release/TrapGunner_Recompiled --disc \"$CUE\""
