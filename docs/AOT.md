# 🧬 Overlays / AOT: o Trap Gunner é 100% residente

Investigação feita em 2026-11-26 com psxrecomp `126ec7f2`, seguindo
`psxrecomp/docs/AOT_SHARDING.md` (seção *When discovery finds no game overlay*).

| Evidência | Resultado |
|---|---|
| Inventário ISO9660 (`tgtool list`) | Um único executável: `SLUS_006.79` (1 024 000 bytes). O resto é dado: `CHR/*.PAK`, `DAT/*`, `MAP/MAP*.PAK`, `STR/` (FMV), `ZERO.NOP` (enchimento) |
| `tools/aot_overlay_spike/extract_generic.py` | `0 PS-X EXE, 0 header-table, 0 raw-code, 0 indexed-archive …; 0 regions` |
| Runtime em gameplay (Story missão 1 e VS MAN no DEPOT) | `overlay_compile.runs = 0`, nenhuma captura em `overlay_captures.json` |

**Conclusão:** todo o código executável fica em `SLUS_006.79`, que o
recompilador já traduz por inteiro para C. Não há nada para sharding AOT, e o
interpretador fica só como rede de segurança. Se algum caminho ainda não
testado (por exemplo, uma fase tardia) gerar captura, o runtime vai registrá-la
em `build-release/overlay_captures.json`. Nesse caso o próximo passo é fazer
um perfil `aot/overlays.json`.
