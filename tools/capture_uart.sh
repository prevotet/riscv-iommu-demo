#!/usr/bin/env bash
# =============================================================================
#  Capture de l'UART de la Genesys2, avec le log gardé.
#
#    tools/capture_uart.sh                 # détecte le port, écrit dans results/
#    tools/capture_uart.sh -o mon.log      # nom de fichier imposé
#    tools/capture_uart.sh -t 120          # silence toléré, en secondes
#    tools/capture_uart.sh -d /dev/ttyUSB1 # port imposé
#
#  Pourquoi ce script plutôt qu'un picocom à la main :
#
#  1. LE LOG. La campagne du 2026-09-08 n'a été sauvegardée nulle part, et
#     l'anomalie « det ≈ 0,52 × tx » a dû être reprise sur le source faute de
#     CSV par itération. Ici le fichier est horodaté et écrit au fil de l'eau
#     dans results/, qui est versionné.
#
#  2. LE PORT QUI DISPARAÎT. Vivado prend le câble par libusb pour le JTAG et
#     détache ftdi_sio des DEUX canaux du FT2232 ; au départ de hw_server les
#     ttyUSB ne reviennent pas tout seuls. On le détecte et on rebinde.
#     Corollaire : programmer le FPGA AVANT d'ouvrir la capture, jamais après.
#
#  3. LE GEL. Une campagne qui se fige n'émet plus rien et un picocom attendrait
#     indéfiniment. Ici un silence prolongé arrête la capture en le disant, et
#     le log contient tout ce qui a précédé -- c'est justement ce qu'on veut
#     lire quand ça gèle.
# =============================================================================
set -uo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
BAUD=115200
IDLE=90
DEV=""
LOG=""

while [[ $# -gt 0 ]]; do
    case "$1" in
        -d) DEV="$2";  shift 2 ;;
        -o) LOG="$2";  shift 2 ;;
        -t) IDLE="$2"; shift 2 ;;
        -h|--help) sed -n '2,30p' "${BASH_SOURCE[0]}"; exit 0 ;;
        *)  echo "Option inconnue : $1" >&2; exit 1 ;;
    esac
done

# -----------------------------------------------------------------------------
#  Trouver l'UART.
#
#  Pas de /dev/ttyUSB1 en dur : le numéro dépend de l'ordre d'énumération et un
#  FT232R separé occupe déjà ttyUSB0 sur cette machine. On vise l'INTERFACE 1
#  du pont FT2232 (0403:6010) de la carte : l'interface 0 est le JTAG,
#  l'interface 1 est l'UART. C'est stable quel que soit le numéro attribué.
# -----------------------------------------------------------------------------
find_uart() {
    local devdir iface tty
    for devdir in /sys/bus/usb/devices/*; do
        [[ -f "$devdir/idVendor" && -f "$devdir/idProduct" ]] || continue
        [[ "$(cat "$devdir/idVendor")"  == "0403" ]] || continue
        [[ "$(cat "$devdir/idProduct")" == "6010" ]] || continue
        iface="$devdir:1.1"
        [[ -d "$iface" ]] || continue
        for tty in "$iface"/tty*; do
            [[ -e "$tty" ]] && { echo "/dev/$(basename "$tty")"; return 0; }
        done
    done
    return 1
}

ft2232_present() {
    local d
    for d in /sys/bus/usb/devices/*; do
        [[ -f "$d/idProduct" ]] || continue
        [[ "$(cat "$d/idVendor" 2>/dev/null)" == "0403" ]] || continue
        [[ "$(cat "$d/idProduct")" == "6010" ]] && return 0
    done
    return 1
}

if [[ -z "$DEV" ]]; then
    DEV="$(find_uart || true)"

    if [[ -z "$DEV" ]] && ft2232_present; then
        echo "Le pont FT2232 est là mais aucun ttyUSB n'y est attaché."
        echo "Signature de Vivado : hw_server a détaché ftdi_sio. Rebind…"
        sudo modprobe -r ftdi_sio 2>/dev/null
        if sudo modprobe ftdi_sio; then
            sleep 1
            DEV="$(find_uart || true)"
            rebind_done=1
        else
            rebind_done=0
        fi
    fi

    if [[ -z "$DEV" ]]; then
        if [[ "${rebind_done:-1}" == "0" ]]; then
            echo "Le rebind n'a pas pu s'exécuter (sudo indisponible ici)." >&2
            echo "Le relancer depuis un terminal :" >&2
            echo "  sudo modprobe -r ftdi_sio && sudo modprobe ftdi_sio" >&2
        elif ft2232_present; then
            echo "Rebind sans effet — débrancher/rebrancher le câble USB de la carte." >&2
        else
            echo "Carte absente : aucun pont FT2232 (0403:6010) sur le bus USB." >&2
        fi
        exit 1
    fi
fi

[[ -c "$DEV" ]] || { echo "$DEV n'est pas un périphérique caractère." >&2; exit 1; }
[[ -r "$DEV" ]] || { echo "$DEV illisible — droits insuffisants sur le port." >&2; exit 1; }

if [[ -z "$LOG" ]]; then
    mkdir -p "$ROOT/results"
    LOG="$ROOT/results/bench_$(date +%F_%H%M%S).log"
fi
[[ -e "$LOG" ]] && { echo "$LOG existe déjà — refus d'écraser." >&2; exit 1; }

stty -F "$DEV" "$BAUD" raw -echo -echoe -echok -crtscts

echo "Port    : $DEV à $BAUD bauds"
echo "Journal : $LOG"
echo "Arrêt   : fin de campagne, ${IDLE}s de silence, ou Ctrl-C."
echo
echo ">>> RESET LA CARTE MAINTENANT <<<   (la capture est ouverte, l'en-tête sera pris)"
echo

# -----------------------------------------------------------------------------
#  Boucle de lecture ligne à ligne. `read -t` est ce qui distingue une campagne
#  finie d'une campagne gelée : sans lui, un gel ressemble à une attente.
# -----------------------------------------------------------------------------
#  `rc` est relevé DANS la boucle : l'état de sortie d'un `while` est celui de
#  son corps, pas celui du `read` qui a expiré. Le lire après coup faisait
#  passer un gel pour une interruption -- et c'est justement le cas qu'on veut
#  nommer correctement ici.
status="interrompu"
rc=0
while true; do
    IFS= read -r -t "$IDLE" line || { rc=$?; break; }
    line="${line%$'\r'}"
    printf '%s\n' "$line"
    printf '%s\n' "$line" >> "$LOG"
    case "$line" in
        *'###### END ######'*|*'# Benchmark complete'*)
            status="campagne terminée"; break ;;
    esac
done < "$DEV"

if (( rc > 128 )); then
    status="SILENCE pendant ${IDLE}s — carte gelée ou campagne interrompue"
elif (( rc > 0 )); then
    status="port fermé (fin de flux)"
fi

echo
echo "--- $status"
echo "--- $(wc -l < "$LOG") lignes dans $LOG"

# Les trois lignes à vérifier avant d'exploiter le moindre chiffre.
echo
grep -E '^# (UNITE|CALIB)' "$LOG" || echo "# (ni UNITE ni CALIB : firmware antérieur au 2026-09-09)"
