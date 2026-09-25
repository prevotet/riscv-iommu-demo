#!/usr/bin/env bash
# =============================================================================
#  tools/load_jtag.sh — charge le firmware par JTAG, SANS carte SD
#
#    tools/load_jtag.sh                 # fw_payload.elf du dernier build OpenSBI
#    tools/load_jtag.sh payloads/x.elf  # une image archivee (ELF : rapide)
#    tools/load_jtag.sh payloads/x.bin  # une image archivee (BIN : ~2 min)
#
#  ORDRE, dans cet ordre et pas un autre :
#    1. ./2_build_HB.sh program        (bitstream ; Vivado doit avoir QUITTE)
#    2. tools/capture_uart.sh          (autre terminal ; attendre qu'il ecoute)
#    3. tools/load_jtag.sh
#
#  Pourquoi cet ordre. capture_uart.sh peut decharger ftdi_sio (modprobe -r)
#  pour rendre les ttyUSB que Vivado a detaches : lance APRES OpenOCD, il lui
#  arracherait le cable en plein chargement. Et la capture doit ecouter avant le
#  resume, sinon l'en-tete du bench est perdu. Sans carte SD, le bootrom tourne
#  en boucle sur « initializing SD... » : c'est normal, reset halt l'interrompt.
#
#  POURQUOI L'ELF. fw_payload.bin fait 2,17 Mo, dont 2 Mio de bourrage entre
#  OpenSBI (0x80000000) et Bao (0x80200000). Les deux segments de l'ELF ne font
#  que ~150 Ko : ~8 s au debit du progbuf (~20 Kio/s), contre ~2 min pour le BIN.
#
#  Sequence reprise de KERONEv2/hypervisor/scripts/load_openocd.sh, eprouvee sur
#  ce design : reset halt, load_image + verify_image, a0 = hartid, a1 = DTB,
#  pc = 0x80000000, resume.
# =============================================================================
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
OPENOCD="${OPENOCD:-/usr/bin/openocd}"
CFG="$ROOT/tools/openocd_genesys2.cfg"
IMG="${1:-$ROOT/opensbi/build/platform/fpga/ariane/firmware/fw_payload.elf}"
READELF="${READELF:-/home/jc/Work/Software/riscv-imac/bin/riscv64-unknown-elf-readelf}"

# DTB : celui que le bootrom passe en a1 lors d'un boot SD, recompile depuis sa
# source. Charge a FW_PAYLOAD_FDT_ADDR (opensbi/platform/fpga/ariane/config.mk),
# comme dans KERONEv2.
DTS="$ROOT/cva6/corev_apu/fpga/src/bootrom/cv64a6.dts"
DTB="$ROOT/build/hw/cv64a6.dtb"
DTB_ADDR=0x82200000
ENTRY=0x80000000

die() { echo "ERREUR : $*" >&2; exit 1; }

# --- Controles, avant de toucher au cable -----------------------------------
[[ -f "$IMG" ]] || die "image introuvable : $IMG"

ver="$("$OPENOCD" --version 2>&1 | head -1 | grep -oE '[0-9]+\.[0-9]+' | head -1 || true)"
[[ -n "$ver" ]] || die "$OPENOCD ne repond pas (OPENOCD=<chemin> pour en choisir un autre)"
if [[ "$(printf '%s\n0.12\n' "$ver" | sort -V | head -1)" != "0.12" ]]; then
    die "OpenOCD $ver : la config exige >= 0.12 (celui de Quartus est 0.11). OPENOCD=/usr/bin/openocd"
fi

if pgrep -x hw_server >/dev/null 2>&1; then
    die "hw_server (Vivado) tient le cable JTAG. Fermer Vivado, ou : pkill -x hw_server"
fi

lsusb 2>/dev/null | grep -q "0403:6010" \
    || die "pont FT2232 de la Genesys2 (0403:6010) absent : carte eteinte ou cable USB JTAG debranche"

case "$IMG" in
    *.elf)
        #  LC_ALL=C : readelf est traduit sur cette machine (« Adresse du point
        #  d'entree »). Sans lui, la recherche ne trouve rien et le script
        #  refusait TOUS les ELF -- vu le 2026-09-11, avant tout essai sur carte.
        entry="$(LC_ALL=C "$READELF" -h "$IMG" | awk '/Entry point/ {print $NF}')"
        [[ -n "$entry" ]] || die "point d'entree illisible dans $IMG ($READELF)"
        [[ "$(( entry ))" == "$(( ENTRY ))" ]] \
            || die "point d'entree $entry, attendu $ENTRY : ce n'est pas un fw_payload OpenSBI"
        LOAD="load_image {$IMG} 0x0 elf"
        VERIFY="verify_image {$IMG} 0x0 elf"
        ;;
    *.bin)
        echo "NB : image BIN, ~2 min de chargement (2 Mio de bourrage). Preferer l'ELF."
        LOAD="load_image {$IMG} $ENTRY bin"
        VERIFY="verify_image {$IMG} $ENTRY bin"
        ;;
    *)  die "extension inconnue : $IMG (.elf ou .bin)" ;;
esac

if [[ ! -f "$DTB" || "$DTS" -nt "$DTB" ]]; then
    command -v dtc >/dev/null || die "dtc absent (sudo apt install device-tree-compiler)"
    mkdir -p "$(dirname "$DTB")"
    dtc -q -I dts -O dtb -o "$DTB" "$DTS"
fi

echo "  image   : ${IMG#$ROOT/} ($(stat -c %s "$IMG") octets, $(date -r "$IMG" '+%F %T'))"
echo "  DTB     : ${DTB#$ROOT/} -> $DTB_ADDR"
echo "  OpenOCD : $OPENOCD ($ver)"
echo

# --- Chargement ---------------------------------------------------------------
#  verify_image apres CHAQUE load_image : une corruption de la DRAM par le JTAG
#  se lit sinon comme un « OpenSBI qui crashe » (piege vecu dans KERONEv2).
"$OPENOCD" -f "$CFG" -c "
    init
    reset halt
    echo \"  chargement de l'image...\"
    $LOAD
    $VERIFY
    echo \"  chargement du DTB...\"
    load_image {$DTB} $DTB_ADDR bin
    verify_image {$DTB} $DTB_ADDR bin
    reg a0 0x0
    reg a1 $DTB_ADDR
    reg pc $ENTRY
    resume
    echo \"  lance : OpenSBI -> Bao -> guest. Voir la capture UART.\"
    shutdown
"
