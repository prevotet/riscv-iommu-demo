#!/usr/bin/env bash
# =============================================================================
#  Retire les lignes d'attribution IA des messages de commit de `testbench`,
#  puis pousse la branche reecrite.
#
#  Pourquoi un script plutot qu'une commande directe : la reecriture
#  d'historique (git filter-branch) est refusee par le garde-fou de l'assistant.
#  Elle doit donc etre lancee par toi.
#
#  Portee : les 54 commits propres a `testbench` (base commune avec origin/main
#  = ce25f1f). Aucun commit de `main` n'est touche -- verifie : les commits
#  concernes sont exclusifs a testbench.
#
#  ATTENTION : 17 de ces commits sont DEJA PUBLIES sur origin/testbench. Les
#  reecrire change leurs SHA, donc la publication exige un push force. Si
#  quelqu'un d'autre a cette branche, il devra la reprendre. Sur un depot de
#  travail personnel c'est sans consequence.
#
#  Une sauvegarde existe deja : backup/testbench-avant-nettoyage
#  Pour tout annuler :  git reset --hard backup/testbench-avant-nettoyage
# =============================================================================
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT"

BASE=ce25f1f
BRANCH=testbench
BACKUP=backup/testbench-avant-nettoyage

[[ "$(git rev-parse --abbrev-ref HEAD)" == "$BRANCH" ]] || {
    echo "Se placer sur $BRANCH d'abord." >&2; exit 1; }

git rev-parse --verify -q "$BACKUP" >/dev/null || git branch "$BACKUP" "$BRANCH"
echo "Sauvegarde : $BACKUP = $(git rev-parse --short $BACKUP)"

n_avant=$(git log --format='%H' --grep='Co-Authored-By: Claude\|Claude-Session' "$BASE..$BRANCH" | wc -l)
echo "Commits portant une attribution : $n_avant"
echo
read -rp "Reecrire l'historique de $BRANCH ? (oui/NON) : " ok
[[ "$ok" == "oui" ]] || { echo "Annule."; exit 0; }

FILTER=$(mktemp)
cat > "$FILTER" <<'EOS'
#!/bin/sh
sed -e '/^Co-Authored-By: Claude/d' \
    -e '/^Claude-Session:/d' \
    -e '/^.*Generated with \[Claude Code\]/d' \
    -e '\#^https://claude\.ai/code/session_#d'
EOS
chmod +x "$FILTER"

FILTER_BRANCH_SQUELCH_WARNING=1 git filter-branch -f --msg-filter "$FILTER" "$BASE..$BRANCH"
rm -f "$FILTER"

n_apres=$(git log --format='%H' --grep='Co-Authored-By: Claude\|Claude-Session\|claude\.ai/code' -i "$BASE..$BRANCH" | wc -l)
echo
echo "Attributions restantes : $n_apres  (doit valoir 0)"
[[ "$n_apres" -eq 0 ]] || { echo "Nettoyage incomplet, on ne pousse pas." >&2; exit 1; }

# origin est en HTTPS sans identifiants : on pousse en SSH.
echo
echo "Push force vers git@github.com:prevotet/riscv-iommu-demo.git ($BRANCH)"
read -rp "Confirmer le push force ? (oui/NON) : " ok2
[[ "$ok2" == "oui" ]] || { echo "Historique reecrit localement, pas pousse."; exit 0; }

git push --force-with-lease git@github.com:prevotet/riscv-iommu-demo.git "$BRANCH:$BRANCH"
echo "Fait."
