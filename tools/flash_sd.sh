#!/usr/bin/env bash
# Écrit le firmware sur la carte SD de la Genesys2, avec garde-fous.
#
#   ./flash_sd.sh /dev/sdX        (le disque, pas la partition)
#
# Refuse tout ce qui n'est pas amovible, non vide, et de taille plausible.
# Ne repartitionne QUE si la disposition attendue (32 Mo + reste) est absente.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
FW="$ROOT/opensbi/build/platform/fpga/ariane/firmware/fw_payload.bin"
DEV="${1:-}"

[[ -n "$DEV" ]]      || { echo "Usage : $0 /dev/sdX" >&2; exit 1; }
[[ -b "$DEV" ]]      || { echo "$DEV n'est pas un périphérique bloc" >&2; exit 1; }
[[ -f "$FW" ]]       || { echo "Firmware absent : $FW" >&2; exit 1; }

name=$(basename "$DEV")

# Amovible : écarte d'emblée sda/sdb, les disques de travail en LVM.
rm=$(cat "/sys/block/$name/removable" 2>/dev/null || echo 0)
[[ "$rm" == "1" ]] || { echo "REFUS : $DEV n'est pas amovible." >&2; exit 1; }

# Taille non nulle : c'est ce qui a piégé la dernière fois (slot vide).
sectors=$(cat "/sys/block/$name/size" 2>/dev/null || echo 0)
(( sectors > 0 )) || { echo "REFUS : $DEV fait 0 secteur — pas de carte insérée." >&2; exit 1; }
gib=$(( sectors * 512 / 1024 / 1024 / 1024 ))
(( gib >= 1 && gib <= 512 )) || { echo "REFUS : taille invraisemblable (${gib} Gio)." >&2; exit 1; }

# Aucune partition montée : on n'écrit pas sous les pieds du système.
if lsblk -nro MOUNTPOINT "$DEV" | grep -q .; then
    echo "REFUS : une partition de $DEV est montée." >&2
    lsblk -o NAME,SIZE,MOUNTPOINT "$DEV" >&2
    exit 1
fi

echo "Cible : $DEV (${gib} Gio, amovible)"
lsblk -o NAME,SIZE,TYPE,MODEL,SERIAL "$DEV"
read -rp "Confirmer l'écriture (oui/NON) : " ok
[[ "$ok" == "oui" ]] || { echo "Annulé."; exit 0; }

# Repartitionner seulement si nécessaire : la partition 1 de 32 Mo est la seule
# chose qu'on écrase, la 2 sert au rootfs de l'autre démo.
p1_mib=$(( $(cat "/sys/block/$name/${name}1/size" 2>/dev/null || echo 0) * 512 / 1024 / 1024 ))
if (( p1_mib != 32 )); then
    echo "Disposition inattendue (p1 = ${p1_mib} Mio) — repartitionnement GPT."
    sudo sgdisk --clear --new=1:2048:+32M --new=2 \
                --typecode=1:3000 --typecode=2:8300 "$DEV" -g
    sudo partprobe "$DEV"
    sleep 1
else
    echo "Disposition déjà correcte (p1 = 32 Mio) — seul le firmware est réécrit."
fi

sudo dd if="$FW" of="${DEV}1" oflag=sync bs=1M status=progress
sync
echo "Firmware écrit sur ${DEV}1."
