#!/usr/bin/env bash
# =============================================================================
#  Versionnement des bitstreams — éviter de resynthétiser sur chaque machine
#
#  La synthèse dure ~46 min et son résultat ne dépend que du RTL et du profil.
#  Plutôt que de la refaire après chaque clone, le .bit est committé et
#  réinstallé dans build/hw/, d'où `2_build_HB.sh program` le lit.
#
#  Chaque bitstream est accompagné d'un fichier .provenance qui enregistre le
#  commit, le profil, et une empreinte des sources RTL. C'est ce dernier point
#  qui compte : sans lui, rien ne distingue un bitstream à jour d'un bitstream
#  périmé, et un .bit sans le correctif resp_slv_t produit des campagnes à zéro
#  DONE qu'on peut passer des heures à réinterpréter. C'est exactement ce qui
#  s'est produit le 2026-09-08.
#
#  Usage :
#    tools/bitstream.sh save  [bench|demo]   après une synthèse : versionne
#    tools/bitstream.sh use   [bench|demo]   après un clone : installe
#    tools/bitstream.sh check [bench|demo]   le .bit correspond-il au RTL ?
#
#  Le profil par défaut est bench.
# =============================================================================
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
STORE="$ROOT/bitstreams"
BUILT="$ROOT/build/hw/ariane_xilinx.bit"

ACTION="${1:-}"
PROFILE="${2:-bench}"

case "$PROFILE" in
    bench|demo) ;;
    *) echo "Profil inconnu : $PROFILE (bench ou demo)" >&2; exit 1 ;;
esac

BIT="$STORE/ariane_xilinx_$PROFILE.bit"
PROV="$STORE/ariane_xilinx_$PROFILE.provenance"

# -----------------------------------------------------------------------------
#  Empreinte des sources qui déterminent le bitstream.
#
#  Uniquement le RTL et le flot de synthèse : bench_runner.c, les configs Bao et
#  OpenSBI n'entrent pas dans le .bit, et les inclure ferait crier au bitstream
#  périmé à chaque changement logiciel. Le commit du sous-module cva6 en fait
#  partie, lui : c'est la base sur laquelle l'overlay est déversé.
# -----------------------------------------------------------------------------
rtl_hash() {
    {
        git -C "$ROOT" rev-parse HEAD:cva6 2>/dev/null || echo "cva6-inconnu"
        find "$ROOT/armor/SRC" "$ROOT/armor/Include" \
             "$ROOT/cva6-overlay" -type f \( -name '*.sv' -o -name '*.svh' \
             -o -name '*.v' -o -name '*.tcl' \) -print0 2>/dev/null \
            | sort -z | xargs -0 sha256sum
    } | sha256sum | cut -d' ' -f1
}

# -----------------------------------------------------------------------------
#  Le dépôt est-il modifié ? Les sous-modules cva6 et bao-hypervisor sont
#  EXCLUS : le build y recopie armor/SRC, cva6-overlay et plat-configs, si bien
#  qu'ils sont sales par construction après toute synthèse. Les compter ferait
#  marquer -dirty toute provenance, y compris celle d'un arbre parfaitement
#  propre, et un marqueur qui s'allume toujours n'apprend plus rien.
#
#  bitstreams/ est EXCLU pour la même raison, d'un cran plus haut : `save` écrit
#  le .bit et le .provenance avant de stamper, donc il se voyait lui-même et
#  toute provenance sortait -dirty. C'est ce qui est arrivé au stamp du
#  2026-09-09 09:13.
# -----------------------------------------------------------------------------
tree_dirty() {
    if [[ -n "$(git -C "$ROOT" status --porcelain --untracked-files=no \
                -- . ':(exclude)cva6' ':(exclude)bao-hypervisor' \
                     ':(exclude)bitstreams')" ]]; then
        echo "-dirty"
    fi
}

case "$ACTION" in

save)
    [[ -f "$BUILT" ]] || { echo "Aucun bitstream à versionner : $BUILT" >&2; exit 1; }
    mkdir -p "$STORE"
    cp -f "$BUILT" "$BIT"
    cat > "$PROV" <<EOF
profil          : $PROFILE
commit          : $(git -C "$ROOT" rev-parse HEAD)
commit court    : $(git -C "$ROOT" rev-parse --short HEAD)$(tree_dirty)
branche         : $(git -C "$ROOT" rev-parse --abbrev-ref HEAD)
sous-module cva6: $(git -C "$ROOT" rev-parse HEAD:cva6 2>/dev/null || echo '?')
date            : $(date -Iseconds)
vivado          : ${VIVADO_VERSION:-2022.2}
empreinte RTL   : $(rtl_hash)
sha256 du .bit  : $(sha256sum "$BIT" | cut -d' ' -f1)
EOF
    echo "Versionné : ${BIT#$ROOT/}"
    echo "Pense à committer $STORE (le .bit fait $(du -h "$BIT" | cut -f1))."
    ;;

use)
    [[ -f "$BIT" ]] || { echo "Aucun bitstream versionné pour le profil $PROFILE" >&2; exit 1; }
    mkdir -p "$(dirname "$BUILT")"
    cp -f "$BIT" "$BUILT"
    echo "Installé dans ${BUILT#$ROOT/}"
    "$0" check "$PROFILE" || true
    ;;

check)
    [[ -f "$PROV" ]] || { echo "Pas de provenance pour le profil $PROFILE" >&2; exit 1; }
    want=$(grep '^empreinte RTL' "$PROV" | cut -d: -f2- | tr -d ' ')
    have=$(rtl_hash)
    echo "provenance : $(grep '^commit court' "$PROV" | cut -d: -f2- | sed 's/^ *//')"
    if [[ "$want" == "$have" ]]; then
        echo "À JOUR : le RTL de l'arbre correspond au bitstream."
    else
        echo "PÉRIMÉ : le RTL a changé depuis cette synthèse." >&2
        echo "  attendu $want" >&2
        echo "  obtenu  $have" >&2
        echo "  -> resynthétiser (BENCH_PROFILE=1 ./2_build_HB.sh fpga --force)" >&2
        exit 2
    fi
    ;;

*)
    sed -n '2,22p' "$0" | sed 's|^#\s\?||'
    exit 1
    ;;
esac
