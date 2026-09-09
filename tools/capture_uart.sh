#!/usr/bin/env bash
# =============================================================================
#  Capture de l'UART de la Genesys2, avec le log gardé.
#
#    tools/capture_uart.sh                 # détecte le port, écrit dans results/
#    tools/capture_uart.sh -o mon.log      # nom de fichier imposé
#    tools/capture_uart.sh -t 120          # silence toléré, en secondes (défaut 300)
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
#  Silence toléré, en SECONDES SANS LE MOINDRE OCTET. Ce n'est pas un délai de
#  ligne : voir la boucle de lecture, qui surveille la taille du journal.
IDLE=120
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
#  L'UART de la carte arrive par un ADAPTATEUR FT232R SÉPARÉ (0403:6001), pas
#  par un canal du pont FT2232 de la Genesys2. C'est le port que l'utilisateur
#  a confirmé le 2026-09-09 : /dev/ttyUSB0.
#
#  Ne pas refaire l'erreur : le pont FT2232 (0403:6010) de la carte expose bien
#  deux ttyUSB, mais aucun des deux ne porte la console. Écouter l'un d'eux ne
#  produit aucun octet et ressemble trait pour trait à une carte gelée -- 90 s
#  de silence perdues là-dessus.
#
#  On cherche donc le FT232R d'abord, le pont FT2232 seulement en secours, et
#  -d passe outre dans tous les cas.
# -----------------------------------------------------------------------------
UART_IFACE="${UART_IFACE:-0}"

#  Premier tty d'une interface USB donnée. $1 = répertoire du device, $2 = numéro
#  d'interface.
iface_tty() {
    local tty
    for tty in "$1:1.$2"/tty*; do
        [[ -e "$tty" ]] && { echo "/dev/$(basename "$tty")"; return 0; }
    done
    return 1
}

#  Tous les devices USB d'un couple vendeur/produit donné.
usb_devices() {
    local d
    for d in /sys/bus/usb/devices/*; do
        [[ -f "$d/idVendor" && -f "$d/idProduct" ]] || continue
        [[ "$(cat "$d/idVendor")"  == "$1" ]] || continue
        [[ "$(cat "$d/idProduct")" == "$2" ]] || continue
        echo "$d"
    done
}

find_uart() {
    local d
    # 1. l'adaptateur FT232R : c'est lui la console.
    for d in $(usb_devices 0403 6001); do
        iface_tty "$d" 0 && return 0
    done
    # 2. secours : un canal du pont de la carte.
    for d in $(usb_devices 0403 6010); do
        iface_tty "$d" "$UART_IFACE" && return 0
    done
    return 1
}

#  L'autre candidat plausible, à conseiller si le port choisi reste muet.
other_uart() {
    local d cur
    cur="$(find_uart || true)"
    for d in $(usb_devices 0403 6001) $(usb_devices 0403 6010); do
        for i in 0 1; do
            t="$(iface_tty "$d" $i || true)"
            [[ -n "$t" && "$t" != "$cur" ]] && { echo "$t"; return 0; }
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
        echo "Aucun adaptateur FT232R, et aucun ttyUSB sur le pont de la carte."
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
            echo "Aucun port série : ni FT232R (0403:6001), ni pont FT2232 (0403:6010)." >&2
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
#  Créé tout de suite : sans cela une capture qui ne reçoit RIEN ne laisse aucun
#  fichier, et le récapitulatif final échoue sur son propre journal.
: > "$LOG" || { echo "Impossible d'écrire $LOG." >&2; exit 1; }

stty -F "$DEV" "$BAUD" raw -echo -echoe -echok -crtscts

echo "Port    : $DEV à $BAUD bauds"
echo "Journal : $LOG"
echo "Arrêt   : fin de campagne, ${IDLE}s de silence, ou Ctrl-C."
echo
echo ">>> RESET LA CARTE MAINTENANT <<<   (la capture est ouverte, l'en-tête sera pris)"
echo

# -----------------------------------------------------------------------------
#  Boucle de lecture, mesurée en OCTETS et non en lignes.
#
#  Une première version lisait ligne par ligne avec `read -t`. Elle coupait tous
#  les boots : la ROM copie 32 Mio depuis la SD et n'imprime qu'UN POINT tous
#  les 1000 secteurs (`sd_copy`, bootrom/src/sd.c), sans retour à la ligne — 65
#  points, ~5 s chacun, soit près de six minutes pendant lesquelles `read` ne
#  rend jamais la main. Des octets arrivaient en permanence et la capture
#  annonçait quand même un gel.
#
#  Ici `cat` écrit dans le journal en continu et on surveille sa TAILLE. Tout
#  octet reçu — point compris — réarme le compteur, et le délai redevient ce
#  qu'il prétend être : du silence réel.
# -----------------------------------------------------------------------------
#  `dd bs=1` et pas `cat` : mesuré, `cat` vers un FICHIER tamponne et ne livre
#  rien avant d'avoir de quoi remplir son bloc — les points de la copie SD
#  restaient invisibles pendant des minutes et la surveillance de taille ne
#  voyait rien bouger. `stdbuf -o0 cat` n'y change rien (cat n'utilise pas
#  stdio). À 115200 bauds, un octet par appel système reste sans effet mesurable.
dd if="$DEV" bs=1 status=none >> "$LOG" &
CATPID=$!
trap 'kill "$CATPID" 2>/dev/null' EXIT INT TERM

off=0
idle=0
status="interrompu"

while :; do
    sleep 1
    size=$(stat -c %s "$LOG" 2>/dev/null || echo "$off")

    if (( size > off )); then
        # Affiché tel quel, retours chariot compris : c'est ce que fait picocom.
        tail -c "+$(( off + 1 ))" "$LOG"
        off=$size
        idle=0
        # Marqueur cherché dans TOUT le journal, pas dans le seul fragment : il
        # peut tomber à cheval sur deux relevés.
        if grep -qa -e '###### END ######' -e '# Benchmark complete' "$LOG"; then
            status="campagne terminée"
            break
        fi
    else
        idle=$(( idle + 1 ))
        if (( idle >= IDLE )); then
            status="SILENCE pendant ${IDLE}s — carte gelée ou campagne interrompue"
            break
        fi
    fi

    kill -0 "$CATPID" 2>/dev/null || { status="port fermé (fin de flux)"; break; }
done

kill "$CATPID" 2>/dev/null
wait "$CATPID" 2>/dev/null

lines=$(wc -l < "$LOG")

echo
echo "--- $status"
echo "--- $lines lignes dans $LOG"

if (( lines == 0 )); then
    alt="$(other_uart || true)"
    echo
    echo "Aucun octet reçu. Dans l'ordre de vraisemblance :"
    echo "  1. la carte n'a pas été resetée après l'ouverture de la capture ;"
    [[ -n "$alt" ]] && \
    echo "  2. mauvais canal — essayer l'autre : $0 -d $alt"
    echo "  3. le FPGA n'est pas programmé, ou le firmware n'a pas démarré."
fi

# Les trois lignes à vérifier avant d'exploiter le moindre chiffre.
echo
grep -E '^# (UNITE|CALIB)' "$LOG" || echo "# (ni UNITE ni CALIB : firmware antérieur au 2026-09-09)"
