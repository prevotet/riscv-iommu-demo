#!/usr/bin/env bash
# =============================================================================
#  Banc xsim : accel_wrap + wrapper ARMOR + aval comportemental
#
#  Usage :   ./run_sim.sh [scenario]     scenario = 0 | 1 | 2 (defaut : 1)
#            ./run_sim.sh all            joue les trois
#            WAVES=1 ./run_sim.sh 1      genere en plus tb_accel_armor.vcd
#            BUG=1   ./run_sim.sh 0      rejoue le defaut resp_t/resp_slv_t
#            DN_LAT=4 ./run_sim.sh 3      aval lent : reproduit un IOMMU reel
#            PROFILE=demo ./run_sim.sh 3   profil DEMO au lieu de BENCH
#
#  Scenarios :
#    0  aval sain                       -- controle, doit atteindre DONE
#    1  aval qui accepte mais ne repond jamais  -- le cas observe sur carte
#    2  aval qui n'accepte rien
#    3  campagne : les scenarios de bench_runner.c
#    4  micro-banc du moniteur de flux : comptage par fronts vs par transferts
#
#  Ni verilator ni iverilog ne sont installes sur cette machine : xsim
#  (xvlog / xelab / xsim) est le seul simulateur disponible.
# =============================================================================
set -euo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT="$(cd "$HERE/../.." && pwd)"
CVA6="$ROOT/cva6"
ARMOR="$ROOT/armor"
WORK="$HERE/work"

VIVADO_SETTINGS="${VIVADO_SETTINGS:-/tools/Xilinx/Vivado/2022.2/settings64.sh}"

if ! command -v xvlog >/dev/null 2>&1; then
    if [[ -f "$VIVADO_SETTINGS" ]]; then
        # shellcheck disable=SC1090
        source "$VIVADO_SETTINGS"
    else
        echo "xvlog introuvable et $VIVADO_SETTINGS absent." >&2
        echo "Definir VIVADO_SETTINGS=<chemin de settings64.sh>." >&2
        exit 1
    fi
fi

# -----------------------------------------------------------------------------
#  Sources.
#
#  L'ordre des paquets compte en mode non-projet : il reprend celui deja valide
#  a l'elaboration Vivado (add_sources.tcl).
#
#  On prend axi_intf.sv et axi_pkg.sv cote cva6, PAS ceux de armor/SRC : ils
#  definissent les memes noms (AXI_BUS, axi_pkg) et xvlog refuserait le
#  doublon. Seul cva6/core/include/axi_intf.sv definit AXI_BUS_MMU, dont
#  accel_wrap a besoin.
# -----------------------------------------------------------------------------
PKGS=(
    "$CVA6/core/include/cv64a6_imafdc_sv39_config_pkg.sv"
    "$CVA6/core/include/riscv_pkg.sv"
    "$CVA6/core/include/ariane_dm_pkg.sv"
    "$CVA6/core/include/ariane_pkg.sv"
    "$CVA6/vendor/pulp-platform/axi/src/axi_pkg.sv"
    "$CVA6/corev_apu/riscv-dbg/src/dm_pkg.sv"
    "$CVA6/corev_apu/tb/ariane_soc_pkg.sv"
    "$CVA6/corev_apu/tb/ariane_axi_soc_pkg.sv"
    "$CVA6/core/include/axi_intf.sv"
)

# Modules ARMOR instancies par wrapper.sv (celui-ci est plat : tous les
# moniteurs et managers sont des feuilles directes).
ARMOR_SRC=(
    "$ARMOR/SRC/ADDR_extractor.sv"
    "$ARMOR/SRC/ID_extractor.sv"
    "$ARMOR/SRC/Interrupt_detector.sv"
    "$ARMOR/SRC/Delay_inserter.sv"
    "$ARMOR/SRC/id_comparator.sv"
    "$ARMOR/SRC/interrupt_monitor.sv"
    "$ARMOR/SRC/outs_req_flow_monitor.sv"
    "$ARMOR/SRC/request_flow_monitor.sv"
    "$ARMOR/SRC/w_skid_buffer.sv"
    "$ARMOR/SRC/request_manager.sv"
    "$ARMOR/SRC/response_manager.sv"
    "$ARMOR/SRC/security_monitor.sv"
    "$ARMOR/SRC/wrapper.sv"
)

DUT=(
    "$ROOT/cva6-overlay/corev_apu/fpga/src/accel_wrap.sv"
)

TB=( "$HERE/tb_accel_armor.sv" )

INCDIRS=(
    "-i" "$CVA6/core/include"
    "-i" "$ARMOR/Include"
    "-i" "$CVA6/vendor/pulp-platform/axi/include"
    "-i" "$CVA6/vendor/pulp-platform/common_cells/include"
)

rm -rf "$WORK"
mkdir -p "$WORK"
cd "$WORK"

DEFINES=()

# BENCH_PROFILE par defaut, comme le bitstream de campagne : fenetre de flux de
# 100 cycles et blocages de ~2 ms, la ou le profil DEMO prend une fenetre de
# 50 000 cycles pour le meme seuil de 8 requetes -- ce qui fait passer neuf
# transactions legitimes en moins d'une milliseconde pour une tempete. Mettre
# PROFILE=demo pour simuler le bitstream de demonstration interactive.
if [[ "${PROFILE:-bench}" == "bench" ]]; then
    DEFINES+=("-d" "BENCH_PROFILE")
fi

# BUG=1 : rejoue le defaut de largeur resp_t / resp_slv_t sur la reponse aval
# (cf. le grand commentaire dans tb_accel_armor.sv). Sert de non-regression.
[[ "${BUG:-0}" == "1" ]] && DEFINES+=("-d" "BUG_RESP_T")

# OBS_CHECK=1 : controle croise des compteurs materiels contre ceux du banc, a
# chaque pas de campagne. DESACTIVE PAR DEFAUT, et ce n'est pas de la prudence
# excessive : ce controle fait quatre lectures CSR de plus par pas, et ces
# quatre lectures suffisent a changer l'issue de SC03 et SC04. Mesure : sans
# elles SC03 donne `req up=8 dn=8, block=0` ; avec elles, `req up=140 dn=3,
# block=478`. Le RTL est inerte -- verifie signal par signal -- c'est bien la
# mesure qui perturbe le mesure.
#
# Consequence a retenir : une campagne de VERIFICATION et une campagne de
# MESURE ne peuvent pas etre le meme run.
[[ "${OBS_CHECK:-0}" == "1" ]] && DEFINES+=("-d" "OBS_CHECK")

# AWFIX=1 : active CTRL[3], le correctif AXI4 qui interdit de retirer un VALID
# deja presente en aval. Le meme bitstream et le meme banc servent donc a
# mesurer la violation (defaut) puis a verifier qu'elle disparait (AWFIX=1).
[[ "${AWFIX:-0}" == "1" ]] && DEFINES+=("-d" "AWFIX")

# WSKID=1 : active CTRL[4], l'etage d'un emplacement sur le canal W. C'est le
# correctif du retrait de VALID mesure sur carte le 2026-09-10. Le comparer au
# mode par defaut est LE controle : les retraits doivent tomber a zero sans que
# la campagne change de verdict.
[[ "${WSKID:-0}" == "1" ]] && DEFINES+=("-d" "WSKID")

# FRESH=1   : CTRL[5], n'admet une adresse que sur un verdict d'identite FRAIS.
#             Ferme une fenetre de deux cycles ou l'adresse etait jugee sur le
#             verdict de la requete precedente.
# TXBLOCK=1 : CTRL[6], blocage transactionnel -- une ecriture engagee en aval
#             se termine au lieu d'etre coupee en SLVERR.
#
# NE JAMAIS tester TXBLOCK sans FRESH : sans verdict frais, « ce qui est
# presente est engage » revient a admettre une ecriture usurpee.
[[ "${FRESH:-0}" == "1" ]]   && DEFINES+=("-d" "FRESH")
[[ "${TXBLOCK:-0}" == "1" ]] && DEFINES+=("-d" "TXBLOCK")

# WCAP=1 : CTRL[7], la dette W est comptee a la CAPTURE dans l'etage W et non a
# la sortie en aval. Correctif du decalage du canal W demontre le 2026-09-11
# (DN_WGATE=1 DN_WLAT=40 : 147 beats partis avec la donnee d'une autre
# ecriture). N'a d'effet qu'avec WSKID=1.
[[ "${WCAP:-0}" == "1" ]]    && DEFINES+=("-d" "WCAP")

# RHOLD=1 : CTRL[8], une reponse B/R presentee au maitre est tenue a l'identique
# jusqu'a son ready, et l'attente de verdict laisse passer les reponses de
# l'aval. Correctif du troisieme site de retrait de VALID (SC03 : b-r = 16 sans
# FRESH, 73 avec, sur carte).
[[ "${RHOLD:-0}" == "1" ]]   && DEFINES+=("-d" "RHOLD")

# WFATE=1 : CTRL[9], sort de chaque AW suivi par transaction (admis ou coupe) ;
# le W d'un AW coupe est absorbe meme hors blocage. Correctif des timeouts de
# l'accelerateur (sur carte, SC02 17/50 sous W_CAPDEBT ; au banc, etat W, beat 0,
# blocage retombe). N'a d'effet qu'avec WSKID=1 ; supplante WCAP.
[[ "${WFATE:-0}" == "1" ]]   && DEFINES+=("-d" "WFATE")

# BFATE=1 : CTRL[10], un B par ecriture, dans l'ordre AXI. Le sort de chaque AW
# (admis ou coupe) est suivi jusqu'a son B : SLVERR fabrique pour un AW coupe,
# une fois son W-last passe ; B de l'aval pour un AW admis. Correctif des B
# fabriques en continu pendant un blocage (un par cycle) et des W-last jamais
# repondus apres (timeout en DRAIN). N'a d'effet qu'avec WSKID=1 et WFATE=1.
[[ "${BFATE:-0}" == "1" ]]   && DEFINES+=("-d" "BFATE")

# RFMCNT=1 : CTRL[12], le moniteur de flux compte les TRANSFERTS d'adresse
# accomplis en aval au lieu des FRONTS de handshake. A 0, deux adresses
# transferees sur deux cycles consecutifs ne comptent que pour une -- sans effet
# sur le generateur de accel_wrap, qui relache aw_valid entre deux AW, mais un
# angle mort pour tout maitre qui pipeline. L'A/B attendu est donc : aucune
# difference sur les scenarios actuels. Une difference serait une information.
[[ "${RFMCNT:-0}" == "1" ]]  && DEFINES+=("-d" "RFMCNT")

# STORMOFF=1 : ajoute a la campagne un pas SC02-STORM sous ENFORCE=0. C'est le
# seul regime ou l'occupation de fenetre se lit sans ecretage -- sous ENFORCE=1
# le moniteur coupe des le seuil atteint et l'occupation vaut 8 par
# construction. Hors campagne par defaut : ses 128 transactions supplementaires
# decalent SC04-MSI, qui sous aval realiste bascule alors de detecte a non
# detecte (fragilite de SC04, pas effet du pas).
[[ "${STORMOFF:-0}" == "1" ]] && DEFINES+=("-d" "STORMOFF")

# PIPE=1 : ajoute a la campagne le pas SC09-PIPE, mode 7 de l'accelerateur --
# seize adresses a la volee AVANT le premier beat de donnees. C'est la tempete
# que decrit la Table 5 du papier et que le mode 4 n'est pas. A jouer dans les
# DEUX arms :
#   PIPE=1              ./run_sim.sh 3   -> aucun verdict (comptage par fronts)
#   PIPE=1 RFMCNT=1     ./run_sim.sh 3   -> STORM
# Le contraste EST le resultat. Hors campagne par defaut : ses transactions
# supplementaires decalent SC04.
[[ "${PIPE:-0}" == "1" ]]    && DEFINES+=("-d" "PIPE")

# THRESH=<n> : seuil du moniteur de flux, ecrit dans CTRL[23:16] (v15). Non
# defini = 0 = valeur de synthese (8). C'est le balayage qui produit la courbe
# detection / faux positifs :
#   for t in 2 3 4 6 8; do THRESH=$t DN_LAT=4 ... ./run_sim.sh 3; done
[[ -n "${THRESH:-}" ]]       && DEFINES+=("-d" "THRESH=$THRESH")

# PIPEDEPTH=<n> : adresses en vol du mode 7 (registre 0x40 de l'accelerateur),
# n'a d'effet qu'avec PIPE=1. Non defini = PIPE_REQS = 16, la profondeur qui a
# gele la carte le 2026-09-13. Le balayage 2, 4, 8, 16 cherche ou le SoC lache ;
# au banc il ne lache pas, faute de crossbar modelise -- ce qu'on verifie ici,
# c'est que le wrapper tient a chaque profondeur.
[[ -n "${PIPEDEPTH:-}" ]]    && DEFINES+=("-d" "PIPEDEPTH=$PIPEDEPTH")

echo "=== xvlog ==="
xvlog -sv --nolog \
      "${DEFINES[@]+"${DEFINES[@]}"}" \
      "${INCDIRS[@]}" \
      "${PKGS[@]}" "${ARMOR_SRC[@]}" "${DUT[@]}" "${TB[@]}"

echo "=== xelab ==="
xelab -debug typical --nolog -timescale 1ns/1ps -s tb_snap tb_accel_armor

run_one() {
    local sc="$1"
    local args=("-testplusarg" "SCENARIO=$sc")
    [[ "${WAVES:-0}" == "1" ]] && args+=("-testplusarg" "WAVES")
    # DN_LAT : latence d'acceptation de l'aval, en cycles (defaut 0 = aval
    # instantane). > 2 reproduit un IOMMU reel, et avec lui le gel SC01.
    [[ -n "${DN_LAT:-}" ]] && args+=("-testplusarg" "DN_LAT=$DN_LAT")
    # DN_WGATE=1 : l'aval ne prend un W que si un AW l'y attend, comme l'IOMMU
    # et le crossbar. A 0 (defaut) il tient w_ready haut et avale aussitot un
    # beat presente sans adresse -- ce qui masquait le decalage de l'etage W.
    [[ "${DN_WGATE:-0}" == "1" ]] && args+=("-testplusarg" "DN_WGATE")
    # DN_WLAT=<n> : latence d'acceptation d'un beat W en aval. Sur carte,
    # ARMORSTALL mesure 40 a 45 cycles : c'est ce qui garde le dernier beat dans
    # l'etage W assez longtemps pour que le W suivant y soit capture.
    [[ -n "${DN_WLAT:-}" ]] && args+=("-testplusarg" "DN_WLAT=$DN_WLAT")
    # DN_AWOUT=<n> : ecritures acceptees en aval dont le B n'est pas rendu. A 1
    # (defaut) l'aval est MONO-TRANSACTION en ecriture, comme depuis le debut :
    # c'est ce qui l'empechait de remplir la file de sort de B_FATE. L'IOMMU de
    # la carte en accepte seize a la volee -- mettre DN_AWOUT=16.
    [[ -n "${DN_AWOUT:-}" ]] && args+=("-testplusarg" "DN_AWOUT=$DN_AWOUT")
    # DN_BLAT=<n> : cycles avant qu'un B du soit presente au wrapper (defaut 0).
    [[ -n "${DN_BLAT:-}" ]] && args+=("-testplusarg" "DN_BLAT=$DN_BLAT")
    # GUARD_MS=<n> : garde-fou global de la simulation, en ms (defaut 2). A
    # relever avec DN_WLAT, sinon la campagne s'arrete avant la fin.
    [[ -n "${GUARD_MS:-}" ]] && args+=("-testplusarg" "GUARD_MS=$GUARD_MS")
    echo
    echo "############### SCENARIO $sc ###############"
    xsim tb_snap --nolog --runall "${args[@]}"
}

case "${1:-1}" in
    all) run_one 0; run_one 1; run_one 2; run_one 3; run_one 4 ;;
    *)   run_one "${1:-1}" ;;
esac
