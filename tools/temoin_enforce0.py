#!/usr/bin/env python3
"""Temoin ENFORCE=0 : ce que l'IOMMU seul fait des memes attaques.

  tools/temoin_enforce0.py results/bench_*.log
  tools/temoin_enforce0.py --tex results/bench_*.log      # + table LaTeX

Les journaux sont tries TOUT SEULS en deux bras a partir de la ligne
`# ARMOR arme : ENFORCE=...` : bras 0 (temoin, ARMOR observe sans bloquer) et
bras 1 (reference). Une campagne dont un garde-fou est en defaut est ecartee et
la raison est dite ; elle n'entre dans aucune moyenne.

CE QUE LA TABLE COMPTE, ET CE QU'ELLE NE COMPTE PAS
---------------------------------------------------
Le piege a deja ete paye le 2026-09-09 : sur un run ENFORCE=0, les colonnes
TP/FP/FN/TN des lignes SUMMARY comptent des **bits de verdict observes**, pas
des transactions bloquees. `armor_sticky_q` est alimente par `armor_status_i`
quelle que soit la valeur d'ENFORCE ; seule l'ACTION est desarmee. Lire ces
colonnes comme un taux de blocage donne « l'IOMMU laisse passer 68 % de SC01 »,
ce qui est faux.

Ce script ne les lit donc pas. Il compte ce que l'ACCELERATEUR a obtenu, sur la
ligne de fin de scenario du firmware :

    # SC01-SPOOF STATUS_final=0x1e | DONE=.. BAN=.. ERR=.. FIN=48 ERRBIT=2

  ABOUTIES  = OK          ST_DONE leve ET ST_ERROR absent : l'attaque est allee
                          au bout sans erreur. C'est le chiffre du temoin.
  ERREUR    = ERRBIT      ST_ERROR leve : coupee par ARMOR (SLVERR, timeout du
                          request manager) ou echue d'elle-meme.
  AUTRE     = N - ABOUTIES - ERREUR, qui doit valoir zero : une transaction
              coupee par ARMOR se termine en SLVERR, donc en ERREUR. Une valeur
              non nulle signale une issue qu'aucun des deux bits ne decrit.

ST_DONE SEUL NE DIT RIEN. Mesure du 2026-09-23 : sous ENFORCE=1 les quatre
scenarios sortent FIN=50 et ERRBIT=50 -- l'accelerateur pose DONE des que sa FSM
rend la main, meme quand toutes ses transactions ont ete coupees, et pose ERROR
par-dessus. Une table batie sur FIN= aurait annonce 100 % d'attaques abouties
dans les DEUX bras.

ET SURTOUT PAS `DONE=`, QUI EST UNE LETTRE, PAS UN BIT. `DONE=` vient de
classify(), une cascade de priorite ou le moindre bit de verdict ARMOR masque
ST_DONE. Sous ENFORCE=1 c'est la bonne lecture. Sous ENFORCE=0 les moniteurs
levent leurs bits SANS rien couper : la transaction aboutit et classify() la
compte quand meme en `BAN=` ou `STORM=`. Lue ainsi, la campagne temoin du
2026-09-23 annoncait 288 attaques « bloquees » sur 300 par un ARMOR desarme.

`FIN=`/`ERRBIT=`/`OK=` datent de ce jour-la. Un journal anterieur ne les porte pas :
le script le dit et ecarte la campagne plutot que de retomber sur `DONE=`.

Et, en regard, ce qu'ARMOR a VU dans les deux bras (ligne ARMORCNT du wrapper
du MHA) : `fail=` pour l'usurpation, `storm=`, `outs=`, `msi=` pour le reste.
C'est la ligne qui porte l'argument : dans le bras 0 ARMOR voit tout et ne
bloque rien, l'attaque aboutit ; dans le bras 1 il voit la meme chose et
l'attaque n'aboutit plus.

`fail=` est le compteur interne du security_monitor : il est LIBRE, non remis a
zero par CNT_CLR, et repasse par 0 tous les 256. Il se lit en ecart entre deux
scenarios, pas en valeur absolue -- le script le signale plutot que de
l'agreger.
"""
import re
import statistics as st
import sys

MAGIC = "0x41524d4f52000012"        # v18
CTRL_ENF1 = "0x331"                 # reference validee carte
CTRL_ENF0 = "0x330"                 # la meme, bit ENFORCE en moins

#  Noms firmware -> noms de l'article (meme table que tools/lot_reference.py).
NOMS = [
    ("SC01-SPOOF", "SC-01", "usurpation d'identite"),
    ("SC02-STORM", "SC-02", "tempete de requetes"),
    ("SC03-OUTS",  "SC-03", "epuisement d'en-vol"),
    ("SC04-MSI",   "SC-04", "inondation MSI"),
]
#  Compteur ARMOR qui porte la detection de chaque scenario.
DETECTEUR = {"SC01-SPOOF": "fail", "SC02-STORM": "storm",
             "SC03-OUTS": "outs", "SC04-MSI": "msi"}


def load(path):
    raw = open(path, "rb").read()
    txt = raw.replace(b"\0", b"").decode("utf-8", "replace").replace("\r", "")
    return raw, txt


def bras(txt):
    """0, 1, ou None si le journal ne le dit pas."""
    m = re.search(r"# ARMOR arme : ENFORCE=(\d)", txt)
    return int(m.group(1)) if m else None


def guards(raw, txt, enf):
    """Garde-fous, adaptes au bras. Liste vide = campagne valide."""
    bad = []
    m = re.search(r"wrap1=(0x[0-9a-f]+) wrap2=(0x[0-9a-f]+)", txt)
    if not m or m.group(1) != MAGIC or m.group(2) != MAGIC:
        bad.append("MAGIC")
    if "###### END ######" not in txt:
        bad.append("fin")
    #  Le CTRL attendu n'est pas le meme dans les deux bras : c'est justement le
    #  bit qu'on enleve. Un temoin qui relit 0x331 n'est pas un temoin.
    attendu = CTRL_ENF0 if enf == 0 else CTRL_ENF1
    m = re.search(r"CTRL relu : w1=(0x[0-9a-f]+) w2=(0x[0-9a-f]+)", txt)
    if not m or m.group(1) != attendu or m.group(2) != attendu:
        vu = f"{m.group(1)}/{m.group(2)}" if m else "absent"
        bad.append(f"CTRL {vu} au lieu de {attendu}")
    if re.search(r"Table 4.*0x[0-9a-f]{8}", txt):
        bad.append("0x110 ecrit")
    if b"\0" in raw:
        bad.append("octets nuls")
    return bad


def fin_scenario(txt, nom):
    """DONE/BLOCK/BAN/STORM/OUTS/MSI/ERR/UNK de la ligne de fin de scenario."""
    m = re.search(rf"^# {re.escape(nom)} STATUS_final=\S+ \| ([^\n]*)", txt, re.M)
    if not m:
        return None
    d = {k: int(v) for k, v in re.findall(r"(\w+)=(\d+)", m.group(1))}
    if "OK" not in d:
        return "vieux"          # journal sans les bits bruts : inexploitable ici
    #  N : chaque iteration rend exactement une lettre de classify().
    d["N"] = sum(d.get(k, 0) for k in
                 ("DONE", "BLOCK", "BAN", "STORM", "OUTS", "MSI", "ERR", "UNK"))
    d["ABOUTIES"] = d["OK"]
    d["ERREUR"] = d["ERRBIT"]
    d["BLOQUEES"] = d["N"] - d["ABOUTIES"] - d["ERREUR"]
    return d


def armorcnt(txt, nom, w="w2"):
    m = re.search(rf"^# ARMORCNT,{re.escape(nom)},{w},([^\n]*)", txt, re.M)
    if not m:
        return None
    return {k: int(v, 0) for k, v in re.findall(r"(\w+)=(0x[0-9a-f]+|\d+)", m.group(1))}


def agrege(campagnes, nom):
    """Somme les issues sur les campagnes d'un bras, garde la detection par campagne."""
    tot = {"ABOUTIES": 0, "BLOQUEES": 0, "ERREUR": 0, "N": 0}
    det = []
    vieux = 0
    for txt in campagnes:
        f = fin_scenario(txt, nom)
        if f == "vieux":
            vieux += 1
            continue
        if f is None:
            continue
        for k in tot:
            tot[k] += f[k]
        c = armorcnt(txt, nom)
        if c is not None and DETECTEUR[nom] in c:
            det.append(c[DETECTEUR[nom]])
    return tot, det, vieux


def pct(n, d):
    return f"{100.0 * n / d:.1f}%" if d else "--"


def main(argv):
    tex = "--tex" in argv
    paths = [a for a in argv if not a.startswith("--")]
    if not paths:
        print(__doc__)
        return 1

    lots = {0: [], 1: []}
    rejets = []
    for p in paths:
        raw, txt = load(p)
        e = bras(txt)
        if e is None:
            rejets.append((p, "bras indetermine (pas de ligne « ARMOR arme »)"))
            continue
        bad = guards(raw, txt, e)
        if bad:
            rejets.append((p, f"ENFORCE={e} : " + ", ".join(bad)))
            continue
        lots[e].append(txt)

    print(f"# Temoin ENFORCE=0 — {len(lots[0])} campagnes temoin, "
          f"{len(lots[1])} campagnes de reference, {len(rejets)} ecartees")
    for p, why in rejets:
        print(f"#   ECARTEE {p.split('/')[-1]} : {why}")
    if not lots[0] or not lots[1]:
        print("# Il faut les DEUX bras pour que la table ait un sens.")
        return 2

    print("#")
    print("# ABOUTIES = terminee sans erreur (ST_DONE et pas ST_ERROR),")
    print("# et surtout pas la lettre DONE= de classify(), que le moindre bit")
    print("# de verdict masque, ni ST_DONE seul, que l'accelerateur pose meme")
    print("# quand tout a ete coupe. Les colonnes TP/FN ne sont pas lues :")
    print("# sous ENFORCE=0 elles comptent des bits observes, pas des blocages.")
    print("#")
    #  Pas de colonne « bloquees » : elle vaut structurellement zero. Une
    #  transaction coupee par ARMOR se termine en SLVERR, donc en ERREUR. La
    #  distinction blocage/erreur n'existe pas du point de vue du maitre, et
    #  pretendre le contraire ferait une colonne de zeros a expliquer.
    print(f"{'scenario':<10} {'attaque':<24} {'bras':<10} "
          f"{'N':>5} {'abouties':>9} {'part':>7} {'en erreur':>10} "
          f"{'autre':>6} {'ARMOR voit':>12}")

    lignes_tex = []
    for fw, art, desc in NOMS:
        ligne_tex = {"art": art, "desc": desc}
        for e in (0, 1):
            tot, det, vieux = agrege(lots[e], fw)
            if vieux:
                print(f"#   {vieux} campagne(s) ENFORCE={e} sans OK= : "
                      f"journal anterieur au 2026-09-23, non exploitable")
            if tot["N"] == 0:
                print(f"{art:<10} {desc:<24} ENFORCE={e}   "
                      f"{'scenario absent des journaux':>46}")
                continue
            #  La detection : mediane des campagnes, et l'ecart s'il existe.
            if det:
                dmed = int(st.median(det))
                dtxt = f"{dmed}" if len(set(det)) == 1 else f"{dmed} [{min(det)}-{max(det)}]"
            else:
                dtxt = "--"
            if fw == "SC01-SPOOF":
                dtxt += "*"
            print(f"{art:<10} {desc:<24} ENFORCE={e}   "
                  f"{tot['N']:>5} {tot['ABOUTIES']:>9} "
                  f"{pct(tot['ABOUTIES'], tot['N']):>7} "
                  f"{tot['ERREUR']:>10} {tot['BLOQUEES']:>6} {dtxt:>12}")
            ligne_tex[e] = tot
        lignes_tex.append(ligne_tex)

    print("#")
    print("# * fail= est un compteur libre, non remis a zero et modulo 256 :")
    print("#   il se lit en ECART entre scenarios, pas en valeur absolue.")

    if tex:
        print("\n" + "=" * 72)
        print("Table LaTeX, prete a coller — remplacer VRAI_LABEL par l'etiquette voulue")
        print("=" * 72)
        print(r"""\begin{table}[t]
\caption{\add{What the IOMMU alone does with the same attacks. The wrapper is
present and its monitors run in both arms; only enforcement is disabled, by
clearing \texttt{CTRL[0]} on the same bitstream. \emph{Completed} counts the
attacks whose transaction finished, that is, reached the memory it aimed at.}}
\label{tbl:VRAI_LABEL}
\begin{tabular*}{\tblwidth}{@{}LLRRR@{}}
\toprule
Attack & Enforcement & Issued & Completed & Detected \\
\midrule""")
        for L in lignes_tex:
            for e, nom in ((0, "off (IOMMU only)"), (1, "on (ARMOR)")):
                if e not in L:
                    continue
                t = L[e]
                print(f"{L['art'] if e == 0 else ''} & {nom} & {t['N']:,} & "
                      f"{t['ABOUTIES']:,} & \\tbd{{}} \\\\".replace(",", "{,}"))
        print(r"""\bottomrule
\end{tabular*}
\end{table}""")
        print("\n# La colonne « Detected » reste en \\tbd{} : la detection se")
        print("# lit sur ARMORCNT et pas sur la ligne de fin de scenario, et")
        print("# fail= demande l'ecart, pas la valeur brute. A remplir a la main")
        print("# depuis la colonne « ARMOR voit » ci-dessus.")
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
