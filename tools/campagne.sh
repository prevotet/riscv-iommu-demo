#!/usr/bin/env bash
# =============================================================================
#  tools/campagne.sh — construire un firmware, puis jouer N campagnes de suite
#
#    tools/campagne.sh <etiquette> <N> [flags ARCH_CPPFLAGS supplementaires...]
#
#  Exemples :
#    tools/campagne.sh REF 6                              # configuration de reference
#    tools/campagne.sh THR12 6 "-DARMOR_THRESH=12"        # balayage du seuil de flux
#    tools/campagne.sh OUT8  6 "-DARMOR_MAXOUTS=8"        # balayage de la borne d'en-vol
#    tools/campagne.sh ENF0  6 "-DARMOR_ENFORCE=0"        # baseline sans blocage
#    OPT_LEVEL=2 tools/campagne.sh ASOS 3 "-DBENCH_ASOS -DBENCH_ASOS_IRQ"  # Tables 13-14
#    tools/campagne.sh TRAJ  3 "-DBENCH_ASOS_TRAJ"     # trajectoire ASOS (autonome)
#    tools/campagne.sh P9d8  6 "-DBENCH_SC09 -DBENCH_SC09_DEPTH=8 \
#                              -DARMOR_RFMCNT=1 -DARMOR_BFATE=1"
#
#  Ecrit UNE LIGNE CSV PAR CAMPAGNE sur stdout, avec les garde-fous en clair :
#    etiquette,index,journal,vMAGIC,end=,CTRL,cfg=,SC01=,SC02=,SC03=,SC04=,FP=,L3p50=,outs=
#
#  POURQUOI CES GARDE-FOUS. Le 2026-09-14 a 15:02 une campagne a tourne sur le
#  bitstream PRECEDENT sans que rien ne le signale : le flash avait echoue et le
#  `| tail` du script masquait son code de retour. On verifie donc a chaque
#  campagne le MAGIC du wrapper, la presence du marqueur de fin, et la valeur
#  relue du registre de configuration. Une ligne dont vMAGIC, end= ou cfg= n'est
#  pas celle attendue est une campagne A JETER, pas a interpreter.
#
#  DEUX COMPTEURS NE SE LISENT PAS ICI, et c'est voulu :
#   - FP= ne voit PAS le fond LHA (qui n'est pas un scenario note). Au seuil 3 il
#     affiche 0 pendant que le wrapper w1 se declenche ~59 000 fois. Pour les faux
#     positifs sur le fond, lire `storm=` dans ARMORCNT,<scenario>,w1.
#   - reqmax est ECRETE par le seuil configure (le verdict remet le compteur a
#     zero). Le vrai pic d'occupation exige -DARMOR_ENFORCE=0.
#
#  Le bitstream N'EST PAS recharge entre les campagnes : load_jtag fait reset
#  halt puis resume, seul le firmware change. Le flasher une fois avant, avec
#  tools/program_fpga.sh — DEUX FOIS, voir doc/REPRENDRE.md.
# =============================================================================
set -uo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
LOGDIR="${LOGDIR:-$(mktemp -d)}"
RISCV_BARE="${RISCV_BARE:-/home/jc/Work/Software/riscv-imac/bin/riscv64-unknown-elf-}"

#  Configuration de reference, validee carte : CTRL relu 0x331.
#  Ne PAS ajouter -DARMOR_WCAP=1, il fait caler le maitre jusqu'au timeout.
BASE_FLAGS="${BASE_FLAGS:--DBENCH_QUICK -DARMOR_WSKID=1 -DARMOR_FRESH=1 -DARMOR_RHOLD=1 -DARMOR_WFATE=1}"

[[ $# -ge 2 ]] || { sed -n '2,12p' "$0"; exit 1; }
LABEL="$1"; N="$2"; shift 2

cd "$ROOT/bao-baremetal-guest"
make clean >/dev/null 2>&1
#  OPT_LEVEL : 0 par defaut, comme le Makefile. Tout chiffre ASOS publie exige
#  OPT_LEVEL=2 (la ligne `# CALIB` doit annoncer 2 cycles, 26 a -O0).
if ! make PLATFORM=cva6 CROSS_COMPILE="$RISCV_BARE" BENCH=1 OPT_LEVEL="${OPT_LEVEL:-0}" \
        ARCH_CPPFLAGS="$BASE_FLAGS $*" -j"$(nproc)" > "$LOGDIR/build_$LABEL.log" 2>&1; then
    echo "$LABEL : ECHEC DE BUILD, voir $LOGDIR/build_$LABEL.log" >&2; exit 1
fi
#  Garde-fou de la memoire bench-flags-not-propagated : seul bench_runner.o doit
#  etre a la racine du build. Si main.o y est, c'est le guest DEMO qui a ete
#  construit et la campagne mesurerait autre chose.
[[ -f build/cva6/bench_runner.o ]] || { echo "$LABEL : bench_runner.o absent" >&2; exit 1; }

cd "$ROOT"
cp bao-baremetal-guest/build/cva6/baremetal.bin build/guests/baremetal.bin
./2_build_HB.sh bao     > "$LOGDIR/bao_$LABEL.log" 2>&1 || { echo "$LABEL : ECHEC bao" >&2; exit 1; }
./2_build_HB.sh opensbi > "$LOGDIR/sbi_$LABEL.log" 2>&1 || { echo "$LABEL : ECHEC opensbi" >&2; exit 1; }

#  hw_server garde le cable ; OpenOCD ne peut pas le partager avec lui.
pkill -x hw_server 2>/dev/null; pkill -x cs_server 2>/dev/null

ELF="$ROOT/opensbi/build/platform/fpga/ariane/firmware/fw_payload.elf"
for ((i=1;i<=N;i++)); do
    #  GARDE-FOU DU 19/09 : une capture qui echoue sans rien ecrire laissait
    #  `ls -t` rendre le journal PRECEDENT, deja valide, et la ligne sortait
    #  propre -- 13 campagnes fantomes d'affilee apres un flash. On compare
    #  donc le journal le plus recent avant et apres la capture.
    AVANT=$(ls -t results/bench_*.log 2>/dev/null | head -1)
    timeout 300 tools/capture_uart.sh -j "$ELF" >/dev/null 2>&1
    L=$(ls -t results/bench_*.log | head -1)
    if [[ "$L" == "$AVANT" || ! -s "$L" ]]; then
        echo "$LABEL,$i,AUCUN-JOURNAL,capture echouee -- campagne a rejouer"
        continue
    fi
    mg=$(grep -m1 "magic"       "$L" | grep -oE "0x41524d4f520000[0-9a-f]{2}" | tail -c3)
    fin=$(grep -c "END ######"  "$L")
    cfg=$(grep -m1 "Table 4"    "$L" | grep -oE "0x[0-9a-f]{8}")
    ctrl=$(grep -m1 "CTRL relu" "$L" | grep -oE "w1=0x[0-9a-f]+")
    s1=$(grep "^SUMMARY-DET,SC01-SPOOF" "$L" | awk -F, '{print $6}')
    s2=$(grep "^SUMMARY-DET,SC02-STORM" "$L" | awk -F, '{print $6}')
    s3=$(grep "^SUMMARY-DET,SC03-OUTS"  "$L" | awk -F, '{print $6}')
    s4=$(grep "^SUMMARY-DET,SC04-MSI"   "$L" | awk -F, '{print $6}')
    fp=$(awk -F, '/^SUMMARY-DET/{f+=$7} END{print f+0}' "$L")
    l3=$(grep "^SUMMARY-DET,SC03-OUTS"  "$L" | awk -F, '{print $12}')
    ov=$(grep -m1 "ARMORCNT,SC03-OUTS,w2" "$L" | grep -oE "outs=[0-9]+" | head -1)
    echo "$LABEL,$i,$(basename "$L"),v$mg,end=$fin,$ctrl,cfg=${cfg:-none},SC01=$s1,SC02=$s2,SC03=$s3,SC04=$s4,FP=$fp,L3p50=$l3,$ov"
done
